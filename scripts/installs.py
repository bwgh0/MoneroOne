#!/usr/bin/env python3
"""
Combined iOS + Android install/churn metrics for MoneroOne.

Pulls:
- iOS first-time downloads + updates: App Store Connect Sales Reports (since launch)
- iOS deletes: App Store Connect Analytics Reports (r6, latest available instance,
  opt-in only sample — Apple does not report deletes from users who haven't opted
  into sharing analytics with developers; treated as undercount)
- Android installs/uninstalls/active: Play Console GCS bucket (exact)

History: appends one snapshot per run to installs_history.jsonl
Weekly aggregates: written to installs_weekly.jsonl (one row per platform per week)
"""
import csv
import glob
import gzip
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta

import jwt as pyjwt

IOS_APP_ID = "6757898541"
IOS_VENDOR = "91081704"
IOS_LAUNCH = date(2026, 1, 22)
ANDROID_PKG = "one.monero.moneroone"
ANDROID_DEV_ID = "8978733019721395633"
# Service account avoids interactive reauth challenges that plague user creds.
ANDROID_SA = "play-deploy@monero-one.iam.gserviceaccount.com"
FIRST_TIME_PT = {"1", "1F", "1T", "1E", "1EP", "1M"}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HISTORY_PATH = os.path.join(SCRIPT_DIR, "installs_history.jsonl")
WEEKLY_PATH = os.path.join(SCRIPT_DIR, "installs_weekly.jsonl")


def ios_token():
    key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
    issuer = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")).read()
    now = int(time.time())
    return pyjwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )


def ios_api_get(url, accept="application/json"):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {ios_token()}",
                                               "Accept": accept})
    return urllib.request.urlopen(req).read()


def ios_fetch_daily_sales(d):
    url = ("https://api.appstoreconnect.apple.com/v1/salesReports"
           f"?filter[frequency]=DAILY&filter[reportDate]={d.isoformat()}"
           "&filter[reportSubType]=SUMMARY&filter[reportType]=SALES"
           f"&filter[vendorNumber]={IOS_VENDOR}&filter[version]=1_0")
    try:
        return gzip.decompress(ios_api_get(url, accept="application/a-gzip")).decode()
    except urllib.error.HTTPError:
        return None


def ios_sales_by_week(end=None):
    """Returns dict[week_start] = {first_time, updates}, plus totals."""
    end = end or date.today()
    weekly = defaultdict(lambda: {"first_time": 0, "updates": 0})
    total_ft = 0
    total_up = 0
    days_with_data = 0
    d = IOS_LAUNCH
    while d <= end:
        out = ios_fetch_daily_sales(d)
        if out:
            days_with_data += 1
            wk = (d - timedelta(days=d.weekday())).isoformat()
            for row in csv.DictReader(out.splitlines(), delimiter="\t"):
                pt = row["Product Type Identifier"].strip()
                units = int(row["Units"])
                if pt in FIRST_TIME_PT:
                    weekly[wk]["first_time"] += units
                    total_ft += units
                else:
                    weekly[wk]["updates"] += units
                    total_up += units
        d += timedelta(days=1)
    return dict(weekly), total_ft, total_up, days_with_data


def ios_fetch_deletes():
    """Pull r6 deletes; any HTTPError in the multi-call analytics flow degrades to
    empty so the core install counts still report. Deletes are opt-in only anyway."""
    try:
        return _ios_fetch_deletes_impl()
    except urllib.error.HTTPError as e:
        print(f"[warn] iOS deletes (Analytics Reports) unavailable: HTTP {e.code} — skipping",
              file=sys.stderr)
        return {}, 0, None, None


def _ios_fetch_deletes_impl():
    """Pull r6 (App Store Installation and Deletion) from freshest available instance.
    Returns dict[week_start] = delete_count, plus total, latest_data_date, source label.
    Apple deletes are opt-in only — undercount."""
    reqs = json.loads(ios_api_get(
        f"https://api.appstoreconnect.apple.com/v1/apps/{IOS_APP_ID}/analyticsReportRequests"))
    # Sort: prefer ONGOING with newest instance, fall back to SNAPSHOT
    best_instance = None
    best_date = None
    source_label = None
    for req in reqs["data"]:
        rid = req["id"]
        access = req["attributes"]["accessType"]
        reports = json.loads(ios_api_get(
            f"https://api.appstoreconnect.apple.com/v1/analyticsReportRequests/{rid}/reports?limit=200"))
        r6 = next((r for r in reports["data"]
                   if r["attributes"]["name"] == "App Store Installation and Deletion Standard"), None)
        if not r6:
            continue
        instances = json.loads(ios_api_get(
            f"https://api.appstoreconnect.apple.com/v1/analyticsReports/{r6['id']}/instances?limit=50"))
        for inst in instances["data"]:
            if inst["attributes"]["granularity"] != "DAILY":
                continue
            pd = inst["attributes"]["processingDate"]
            if best_date is None or pd > best_date:
                best_date = pd
                best_instance = inst["id"]
                source_label = f"{access}/{pd}"
    if not best_instance:
        return {}, 0, None, None
    segs = json.loads(ios_api_get(
        f"https://api.appstoreconnect.apple.com/v1/analyticsReportInstances/{best_instance}/segments"))
    weekly = defaultdict(int)
    total = 0
    earliest = None
    latest = None
    for seg in segs["data"]:
        raw = urllib.request.urlopen(seg["attributes"]["url"]).read()
        text = gzip.decompress(raw).decode()
        for row in csv.DictReader(text.splitlines(), delimiter="\t"):
            if row["Event"] != "Delete":
                continue
            d = datetime.fromisoformat(row["Date"]).date()
            wk = (d - timedelta(days=d.weekday())).isoformat()
            cnt = int(row["Counts"])
            weekly[wk] += cnt
            total += cnt
            earliest = min(earliest, d) if earliest else d
            latest = max(latest, d) if latest else d
    return dict(weekly), total, (earliest, latest), source_label


def _gsutil_cp(src, out_dir, account=None):
    """Run gsutil cp under an optional account. Returns (ok, stderr)."""
    env = {**os.environ}
    if account:
        env["CLOUDSDK_CORE_ACCOUNT"] = account
    r = subprocess.run(
        ["gsutil", "-o", "GSUtil:parallel_process_count=1", "-m", "cp", src, out_dir + "/"],
        env=env, capture_output=True, text=True,
    )
    return r.returncode == 0, r.stderr


def _gsutil_cp_failover(src, out_dir, label):
    """Prefer service account (no interactive reauth); fall back to active user creds.
    Raises loudly if both fail — never silently returns empty."""
    ok, err = _gsutil_cp(src, out_dir, account=ANDROID_SA)
    if ok:
        return
    ok_u, err_u = _gsutil_cp(src, out_dir, account=None)
    if ok_u:
        print(f"  [warn] SA denied for {label} — used user creds (will reauth-expire).",
              file=sys.stderr)
        return
    raise RuntimeError(
        f"Android pull failed for {label} (service account AND user creds).\n"
        f"  SA ({ANDROID_SA}):\n    {err.strip()}\n"
        f"  user creds:\n    {err_u.strip()}\n"
        "Fix: grant the SA bulk-report access in Play Console, "
        "or run `gcloud auth login` to refresh user creds."
    )


def android_pull(out_dir="/tmp/play_installs"):
    os.makedirs(out_dir, exist_ok=True)
    src = f"gs://pubsite_prod_{ANDROID_DEV_ID}/stats/installs/installs_{ANDROID_PKG}_*_overview.csv"
    _gsutil_cp_failover(src, out_dir, "stats/installs")
    install_events = 0
    uninstall_events = 0
    first_user_installs = 0
    latest_active = 0
    latest_date = ""
    weekly = defaultdict(lambda: {"installs": 0, "uninstalls": 0})
    files = sorted(glob.glob(f"{out_dir}/*overview.csv"))
    if not files:
        raise RuntimeError(f"Android pull returned no CSVs in {out_dir} — bucket empty or wrong path.")
    for f in files:
        with open(f, encoding="utf-16") as fh:
            for row in csv.DictReader(fh):
                d = datetime.fromisoformat(row["Date"]).date()
                wk = (d - timedelta(days=d.weekday())).isoformat()
                weekly[wk]["installs"] += int(row["Daily User Installs"])
                weekly[wk]["uninstalls"] += int(row["Daily User Uninstalls"])
                install_events += int(row["Install events"])
                uninstall_events += int(row["Uninstall events"])
                first_user_installs += int(row["Daily User Installs"])
                if row["Date"] > latest_date:
                    latest_date = row["Date"]
                    latest_active = int(row["Active Device Installs"])
    return {
        "active_installs": latest_active,
        "as_of": latest_date,
        "first_user_installs": first_user_installs,
        "install_events": install_events,
        "uninstall_events": uninstall_events,
        "weekly": dict(weekly),
    }


def android_store_performance(out_dir="/tmp/play_sp"):
    """Play Console store-listing conversion: visitors -> acquisitions, by traffic
    source and country. Source of truth for Android funnel/discovery."""
    os.makedirs(out_dir, exist_ok=True)
    base = f"gs://pubsite_prod_{ANDROID_DEV_ID}/stats/store_performance/store_performance_{ANDROID_PKG}_*"
    _gsutil_cp_failover(base + "_traffic_source.csv", out_dir, "store_performance/traffic_source")
    _gsutil_cp_failover(base + "_country.csv", out_dir, "store_performance/country")
    by_source = defaultdict(lambda: [0, 0])   # source -> [visitors, acquisitions]
    by_country = defaultdict(lambda: [0, 0])
    for f in sorted(glob.glob(f"{out_dir}/*traffic_source.csv")):
        with open(f, encoding="utf-16") as fh:
            for row in csv.DictReader(fh):
                by_source[row["Traffic source"]][0] += int(row["Store listing visitors"])
                by_source[row["Traffic source"]][1] += int(row["Store listing acquisitions"])
    for f in sorted(glob.glob(f"{out_dir}/*country.csv")):
        with open(f, encoding="utf-16") as fh:
            for row in csv.DictReader(fh):
                by_country[row["Country / region"]][0] += int(row["Store listing visitors"])
                by_country[row["Country / region"]][1] += int(row["Store listing acquisitions"])
    return {"by_source": dict(by_source), "by_country": dict(by_country)}


def ios_report_rows(name, granularity="WEEKLY", access_type="ONGOING"):
    """Return all rows from a named App Store Connect Analytics report, across every
    instance of the given granularity. ONGOING access has the rolling data; the
    ONE_TIME_SNAPSHOT request is usually empty."""
    reqs = json.loads(ios_api_get(
        f"https://api.appstoreconnect.apple.com/v1/apps/{IOS_APP_ID}/analyticsReportRequests"))
    rep_id = None
    for req in reqs["data"]:
        if req["attributes"]["accessType"] != access_type:
            continue
        reports = json.loads(ios_api_get(
            f"https://api.appstoreconnect.apple.com/v1/analyticsReportRequests/{req['id']}/reports?limit=200"))
        for r in reports["data"]:
            if r["attributes"]["name"] == name:
                rep_id = r["id"]
    if not rep_id:
        return []
    insts = json.loads(ios_api_get(
        f"https://api.appstoreconnect.apple.com/v1/analyticsReports/{rep_id}/instances?limit=50"))
    rows = []
    for inst in insts["data"]:
        if inst["attributes"]["granularity"] != granularity:
            continue
        segs = json.loads(ios_api_get(
            f"https://api.appstoreconnect.apple.com/v1/analyticsReportInstances/{inst['id']}/segments"))
        for s in segs["data"]:
            txt = gzip.decompress(urllib.request.urlopen(s["attributes"]["url"]).read()).decode()
            rows.extend(csv.DictReader(txt.splitlines(), delimiter="\t"))
    return rows


def ios_funnel():
    """iOS discovery funnel from Analytics Reports. NOTE: at low volume Apple
    privacy-thresholds these reports, so per-territory/source COUNTS are a sampled
    subset — use for direction (mix, ratios), not absolute totals (sales report is
    truth for totals). ONGOING reports cover only a rolling recent window."""
    events = defaultdict(int)
    impr_sources = defaultdict(int)
    for row in ios_report_rows("App Store Discovery and Engagement Standard"):
        c = int(row["Counts"])
        events[row["Event"]] += c
        if row["Event"] == "Impression":
            impr_sources[row["Source Type"]] += c
    dl_terr = defaultdict(int)
    dl_total = 0
    for row in ios_report_rows("App Downloads Detailed"):
        if row.get("Download Type") and "First" not in row["Download Type"]:
            continue
        c = int(row["Counts"])
        dl_total += c
        dl_terr[row["Territory"]] += c
    return {
        "events": dict(events),
        "impr_sources": dict(impr_sources),
        "dl_territories": dict(dl_terr),
        "dl_sampled_total": dl_total,
    }


def append_jsonl(path, row):
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")


def write_weekly(ios_weekly, ios_deletes, android_weekly):
    """Replace weekly file with full computed history."""
    weeks = sorted(set(ios_weekly.keys()) | set(ios_deletes.keys()) | set(android_weekly.keys()))
    with open(WEEKLY_PATH, "w") as f:
        for wk in weeks:
            row = {
                "week": wk,
                "ios_first_time": ios_weekly.get(wk, {}).get("first_time", 0),
                "ios_updates": ios_weekly.get(wk, {}).get("updates", 0),
                "ios_deletes_optin": ios_deletes.get(wk, 0),
                "android_installs": android_weekly.get(wk, {}).get("installs", 0),
                "android_uninstalls": android_weekly.get(wk, {}).get("uninstalls", 0),
            }
            f.write(json.dumps(row) + "\n")


def print_funnel():
    """Acquisition/discovery funnel for both platforms (no in-app analytics —
    only what Apple/Google already report)."""
    print("Pulling Android store performance...", file=sys.stderr)
    sp = android_store_performance()
    print("Pulling iOS discovery (Analytics Reports)...", file=sys.stderr)
    f = ios_funnel()

    print()
    print("=== Android funnel — store listing (lifetime, EXACT) ===")
    print(f"  {'traffic source':<26}{'visitors':>9}{'acq':>7}{'conv':>7}")
    tv = ta = 0
    for s, (v, ac) in sorted(sp["by_source"].items(), key=lambda x: -x[1][0]):
        print(f"  {s:<26}{v:>9}{ac:>7}{(ac/v if v else 0):>6.0%}")
        tv += v; ta += ac
    print(f"  {'TOTAL':<26}{tv:>9}{ta:>7}{(ta/tv if tv else 0):>6.0%}")
    countries = sorted(sp["by_country"].items(), key=lambda x: -x[1][1])
    named = [(c, v) for c, v in countries if c not in ("Other", "")]
    if named:
        print("  top countries by acquisitions:")
        for c, (v, ac) in named[:8]:
            print(f"    {c:<22}acq {ac:>5}  conv {(ac/v if v else 0):.0%}")
    else:
        print("  (countries anonymized to 'Other' — volume below Google's reporting threshold)")

    print()
    print("=== iOS funnel — discovery & engagement (rolling window, SAMPLED) ===")
    ev = f["events"]
    for k in ("Impression", "Page view", "Tap"):
        if k in ev:
            print(f"  {k:<14}{ev[k]:>7}")
    if f["impr_sources"]:
        print("  impression source:")
        tot = sum(f["impr_sources"].values()) or 1
        for s, c in sorted(f["impr_sources"].items(), key=lambda x: -x[1]):
            print(f"    {s:<24}{c:>6}  {c/tot:.0%}")
    terr = sorted(f["dl_territories"].items(), key=lambda x: -x[1])
    if terr and f["dl_sampled_total"]:
        t = f["dl_sampled_total"]
        print(f"  download mix by territory (sampled subset, n={t}):")
        for c, n in terr[:8]:
            print(f"    {c:<8}{n:>5}  {n/t:.0%}")
    print("  NOTE: iOS analytics are privacy-thresholded at low volume — treat counts")
    print("        as directional (mix/ratios), not absolute. Sales report = true totals.")


def main():
    funnel = "--funnel" in sys.argv
    print("Pulling iOS sales reports (~60s)...", file=sys.stderr)
    ios_weekly, ios_ft, ios_up, ios_days = ios_sales_by_week()
    print("Pulling iOS deletes (Analytics Reports)...", file=sys.stderr)
    ios_deletes_weekly, ios_deletes_total, ios_deletes_range, ios_deletes_source = ios_fetch_deletes()
    print("Pulling Android Play stats...", file=sys.stderr)
    a = android_pull()

    android_retention = a["active_installs"] / a["first_user_installs"] if a["first_user_installs"] else 0
    ios_active_est = round(ios_ft * android_retention)

    snapshot = {
        "ts": date.today().isoformat(),
        "ios_first_time": ios_ft,
        "ios_updates": ios_up,
        "ios_deletes_optin_total": ios_deletes_total,
        "ios_deletes_optin_range": [ios_deletes_range[0].isoformat(), ios_deletes_range[1].isoformat()] if ios_deletes_range else None,
        "ios_deletes_source": ios_deletes_source,
        "ios_active_est": ios_active_est,
        "android_active": a["active_installs"],
        "android_as_of": a["as_of"],
        "android_first_user_installs": a["first_user_installs"],
        "android_install_events": a["install_events"],
        "android_uninstall_events": a["uninstall_events"],
        "total_lifetime_first_time": ios_ft + a["first_user_installs"],
        "total_active_est": ios_active_est + a["active_installs"],
    }
    append_jsonl(HISTORY_PATH, snapshot)
    write_weekly(ios_weekly, ios_deletes_weekly, a["weekly"])

    print()
    print(f"=== Android (data through {a['as_of']}) ===")
    print(f"  Active installs (exact): {a['active_installs']}")
    print(f"  Lifetime first-time user installs: {a['first_user_installs']}")
    print(f"  Lifetime uninstall events: {a['uninstall_events']}")
    churn_a = a["uninstall_events"] / a["first_user_installs"] if a["first_user_installs"] else 0
    print(f"  Lifetime churn rate: {churn_a:.0%}")
    print(f"  Retention: {android_retention:.0%}")

    print()
    print(f"=== iOS ===")
    print(f"  Sales data: {ios_days} days through {date.today().isoformat()}")
    print(f"  Lifetime first-time downloads: {ios_ft}")
    print(f"  Updates served: {ios_up}")
    if ios_deletes_range:
        d0, d1 = ios_deletes_range
        weeks = max(1, (d1 - d0).days / 7)
        print(f"  Reported deletes (opt-in only): {ios_deletes_total} over {d0}..{d1} (~{ios_deletes_total/weeks:.0f}/wk reported)")
        print(f"  Deletes source: {ios_deletes_source}")
    else:
        print(f"  Reported deletes: no data yet (ONGOING analytics request just created — populates in 24-48h)")
    print(f"  Active installs (estimated, Android retention applied): ~{ios_active_est}")

    print()
    print(f"=== TOTAL ===")
    print(f"  Lifetime first-time installs: {snapshot['total_lifetime_first_time']}")
    print(f"  Estimated active install base: ~{snapshot['total_active_est']}")

    print()
    print("=== Recent weekly trend (last 8 weeks both platforms) ===")
    print(f"{'week':<12} {'iOS_ft':>7} {'iOS_del':>8} {'And_in':>7} {'And_un':>7} {'net_gross':>10}")
    weeks_all = sorted(set(ios_weekly.keys()) | set(ios_deletes_weekly.keys()) | set(a["weekly"].keys()))
    for wk in weeks_all[-8:]:
        ift = ios_weekly.get(wk, {}).get("first_time", 0)
        idel = ios_deletes_weekly.get(wk, 0)
        ai = a["weekly"].get(wk, {}).get("installs", 0)
        au = a["weekly"].get(wk, {}).get("uninstalls", 0)
        net = (ift + ai) - (idel + au)
        print(f"{wk:<12} {ift:>7} {idel:>8} {ai:>7} {au:>7} {net:>10}")
    if funnel:
        print_funnel()

    print()
    print(f"Snapshot saved → {HISTORY_PATH}")
    print(f"Weekly series → {WEEKLY_PATH}")
    if not funnel:
        print("(run with --funnel for acquisition/discovery breakdown)")


if __name__ == "__main__":
    main()
