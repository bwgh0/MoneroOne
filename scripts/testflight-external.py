#!/usr/bin/env python3
"""
Push a TestFlight build to the External Testers group with What to Test notes.

CI (testflight.yml) uploads each v* tag to TestFlight, where it lands in the
Internal group with no notes. This script does the follow-up, idempotently:

  1. find the build for the tag (waits while App Store Connect processes it)
  2. set the en-US "What to Test" notes
  3. add the build to the External Testers group
  4. submit it for Beta App Review (skipped if a submission already exists)

Usage:
  scripts/testflight-external.py --tag v1.0.9-2 --notes-file notes.txt [--wait] [--dry-run]
  scripts/testflight-external.py --tag v1.0.9-2 --notes "- Fixed X\n- Fixed Y"
  scripts/testflight-external.py --status          # last builds + groups + notes

Credentials: ~/.appstoreconnect/.env (APP_STORE_CONNECT_API_KEY_ID, _ISSUER_ID)
and ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8. Same as installs.py.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt as pyjwt

APP_ID = "6757898541"
EXTERNAL_GROUP_NAME = "External Testers"
BASE = "https://api.appstoreconnect.apple.com"


def load_env():
    path = os.path.expanduser("~/.appstoreconnect/.env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k, v)


def token():
    key_id = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
    issuer = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")).read()
    now = int(time.time())
    return pyjwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )


def call(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        raw = urllib.request.urlopen(req).read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} {method} {url}\n{e.read().decode()}")


def parse_tag(tag):
    m = re.fullmatch(r"v?(\d+\.\d+\.\d+)-(\d+)", tag)
    if not m:
        sys.exit(f"tag must look like v1.2.3-4, got {tag!r}")
    return m.group(1), m.group(2)


def find_build(version, build):
    r = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={build}"
                    f"&filter[preReleaseVersion.version]={version}"
                    "&include=betaGroups,betaAppReviewSubmission,betaBuildLocalizations"
                    "&fields[builds]=version,processingState,expired,betaGroups,"
                    "betaAppReviewSubmission,betaBuildLocalizations"
                    "&fields[betaGroups]=name&fields[betaAppReviewSubmissions]=betaReviewState"
                    "&fields[betaBuildLocalizations]=locale,whatsNew")
    if not r["data"]:
        return None
    b = r["data"][0]
    inc = {(i["type"], i["id"]): i for i in r.get("included", [])}
    rel = b["relationships"]
    sub = rel.get("betaAppReviewSubmission", {}).get("data")
    return {
        "id": b["id"],
        "state": b["attributes"]["processingState"],
        "expired": b["attributes"]["expired"],
        "groups": [inc[("betaGroups", g["id"])]["attributes"]["name"]
                   for g in rel.get("betaGroups", {}).get("data", [])],
        "review": inc[("betaAppReviewSubmissions", sub["id"])]["attributes"]["betaReviewState"] if sub else None,
        "localizations": {inc[("betaBuildLocalizations", l["id"])]["attributes"]["locale"]:
                          (l["id"], inc[("betaBuildLocalizations", l["id"])]["attributes"].get("whatsNew"))
                          for l in rel.get("betaBuildLocalizations", {}).get("data", [])},
    }


def external_group_id():
    r = call("GET", f"/v1/apps/{APP_ID}/betaGroups?fields[betaGroups]=name,isInternalGroup")
    for g in r["data"]:
        if g["attributes"]["name"] == EXTERNAL_GROUP_NAME and not g["attributes"]["isInternalGroup"]:
            return g["id"]
    sys.exit(f"beta group {EXTERNAL_GROUP_NAME!r} not found")


def status():
    r = call("GET", f"/v1/builds?filter[app]={APP_ID}&sort=-uploadedDate&limit=5"
                    "&include=preReleaseVersion,betaGroups,betaAppReviewSubmission,betaBuildLocalizations"
                    "&fields[builds]=version,uploadedDate,processingState,preReleaseVersion,betaGroups,"
                    "betaAppReviewSubmission,betaBuildLocalizations"
                    "&fields[preReleaseVersions]=version&fields[betaGroups]=name"
                    "&fields[betaAppReviewSubmissions]=betaReviewState"
                    "&fields[betaBuildLocalizations]=locale,whatsNew")
    inc = {(i["type"], i["id"]): i for i in r.get("included", [])}
    for b in r["data"]:
        a, rel = b["attributes"], b["relationships"]
        ver = inc[("preReleaseVersions", rel["preReleaseVersion"]["data"]["id"])]["attributes"]["version"]
        sub = rel.get("betaAppReviewSubmission", {}).get("data")
        review = inc[("betaAppReviewSubmissions", sub["id"])]["attributes"]["betaReviewState"] if sub else "-"
        groups = ", ".join(inc[("betaGroups", g["id"])]["attributes"]["name"]
                           for g in rel.get("betaGroups", {}).get("data", [])) or "-"
        print(f"{ver} ({a['version']})  {a['processingState']}  review={review}  groups={groups}  {a['uploadedDate']}")
        for l in rel.get("betaBuildLocalizations", {}).get("data", []):
            notes = inc[("betaBuildLocalizations", l["id"])]["attributes"].get("whatsNew")
            if notes:
                print("    " + notes.replace("\n", "\n    "))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", help="release tag, e.g. v1.0.9-2")
    ap.add_argument("--notes", help="What to Test text (\\n for newlines)")
    ap.add_argument("--notes-file", help="file containing What to Test text")
    ap.add_argument("--wait", action="store_true", help="poll until the build exists and is VALID")
    ap.add_argument("--timeout", type=int, default=40, help="minutes to wait (default 40)")
    ap.add_argument("--no-review", action="store_true", help="skip Beta App Review submission")
    ap.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    ap.add_argument("--status", action="store_true", help="print recent builds and exit")
    args = ap.parse_args()

    load_env()
    if args.status:
        return status()
    if not args.tag:
        ap.error("--tag is required")
    if args.notes_file:
        notes = open(args.notes_file).read().strip()
    elif args.notes:
        notes = args.notes.replace("\\n", "\n").strip()
    else:
        ap.error("--notes or --notes-file is required")

    version, build_no = parse_tag(args.tag)
    deadline = time.time() + args.timeout * 60
    while True:
        b = find_build(version, build_no)
        if b and b["state"] == "VALID":
            break
        if b and b["state"] in ("FAILED", "INVALID"):
            sys.exit(f"build {version} ({build_no}) processingState={b['state']}")
        if not args.wait:
            sys.exit(f"build {version} ({build_no}) " + (f"is {b['state']}" if b else "not in App Store Connect yet") + " (use --wait)")
        if time.time() > deadline:
            sys.exit(f"timed out waiting for {version} ({build_no})")
        print(f"waiting: {version} ({build_no}) " + (f"is {b['state']}" if b else "not uploaded yet"), flush=True)
        time.sleep(30)

    print(f"build {version} ({build_no}) id={b['id']} groups={b['groups']} review={b['review']}")
    if b["expired"]:
        sys.exit("build is expired")
    prefix = "[dry-run] " if args.dry_run else ""

    # 1. What to Test
    loc = b["localizations"].get("en-US")
    if loc and loc[1] == notes:
        print("notes: unchanged")
    elif loc:
        print(f"{prefix}notes: update en-US")
        if not args.dry_run:
            call("PATCH", f"/v1/betaBuildLocalizations/{loc[0]}", {"data": {
                "type": "betaBuildLocalizations", "id": loc[0], "attributes": {"whatsNew": notes}}})
    else:
        print(f"{prefix}notes: create en-US")
        if not args.dry_run:
            call("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})

    # 2. External Testers group
    if EXTERNAL_GROUP_NAME in b["groups"]:
        print("group: already in External Testers")
    else:
        print(f"{prefix}group: add to External Testers")
        if not args.dry_run:
            call("POST", f"/v1/betaGroups/{external_group_id()}/relationships/builds",
                 {"data": [{"type": "builds", "id": b["id"]}]})

    # 3. Beta App Review
    if args.no_review:
        print("review: skipped (--no-review)")
    elif b["review"]:
        print(f"review: already submitted ({b['review']})")
    else:
        print(f"{prefix}review: submit")
        if not args.dry_run:
            r = call("POST", "/v1/betaAppReviewSubmissions", {"data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
            print(f"review: {r['data']['attributes']['betaReviewState']}")

    if not args.dry_run:
        b = find_build(version, build_no)
        print(f"done: groups={b['groups']} review={b['review']}")


if __name__ == "__main__":
    main()
