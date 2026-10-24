import XCTest
@testable import MoneroOne

/// The What's New banner rules: per install, a fresh install never sees it,
/// an update with wallets does until the X, the sheet or 30 days, and a
/// later big update shows it again.
final class WhatsNewTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func entry(_ major: Int, _ minor: Int) -> WhatsNewEntry {
        WhatsNewEntry(version: NotesVersion(major: major, minor: minor), highlights: [], improvements: [])
    }

    private func gate(app: String = "1.1.0", entries: [WhatsNewEntry]? = nil) -> WhatsNewGate {
        WhatsNewGate(defaults: defaults, entries: entries ?? [entry(1, 1)], appVersion: NotesVersion(app))
    }

    private func days(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: start)!
    }

    // MARK: - Launch

    func testFreshInstallMarksTheNewestEntrySeenWithNoBanner() {
        gate().launchCheck(hadWalletFiles: false)
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.1")
        XCTAssertNil(gate().bannerEntry(now: start))
    }

    func testUpdateWithWalletsShowsTheBanner() {
        gate().launchCheck(hadWalletFiles: true)
        XCTAssertNil(defaults.string(forKey: WhatsNewGate.lastSeenKey))
        XCTAssertEqual(gate().bannerEntry(now: start)?.version, NotesVersion(major: 1, minor: 1))
    }

    func testAWalletMadeAfterAFreshInstallNeverBringsTheBanner() {
        gate().launchCheck(hadWalletFiles: false)
        // The next launch has a wallet now; the stored value decides.
        gate().launchCheck(hadWalletFiles: true)
        XCTAssertNil(gate().bannerEntry(now: start))
    }

    func testAnUpdateWithNoWalletYetShowsNoBanner() {
        let entries = [entry(1, 1), entry(1, 2)]
        // A fresh 1.1 install that never made a wallet.
        gate(app: "1.1.0", entries: entries).launchCheck(hadWalletFiles: false)
        // The 1.2 update launches, still with no wallet.
        let later = gate(app: "1.2.0", entries: entries)
        later.launchCheck(hadWalletFiles: false)
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.2")
        XCTAssertNil(later.bannerEntry(now: start))
    }

    func testAnUpdateWithWalletsKeepsTheBannerAtEveryLaunch() {
        let entries = [entry(1, 1), entry(1, 2)]
        defaults.set("1.1", forKey: WhatsNewGate.lastSeenKey)
        let later = gate(app: "1.2.0", entries: entries)
        later.launchCheck(hadWalletFiles: true)
        later.launchCheck(hadWalletFiles: true)
        XCTAssertEqual(later.bannerEntry(now: start)?.version, NotesVersion(major: 1, minor: 2))
    }

    // MARK: - X and sheet

    func testCloseMarksTheEntrySeen() {
        let g = gate()
        let shown = try! XCTUnwrap(g.bannerEntry(now: start))
        g.bannerShown(shown, now: start)
        g.markSeen(shown)
        XCTAssertNil(gate().bannerEntry(now: start))
        XCTAssertNil(defaults.object(forKey: WhatsNewGate.firstShownKey))
    }

    @MainActor
    func testOpeningTheSheetMarksSeenButKeepsTheBannerUntilItCloses() {
        let model = WhatsNewModel(gate: gate(), now: { self.start })
        let shown = try! XCTUnwrap(model.bannerEntry)
        model.openFromBanner(shown)
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.1")
        XCTAssertNotNil(model.bannerEntry, "The banner leaves after the sheet closes")
        model.sheetClosed()
        XCTAssertNil(model.bannerEntry)
    }

    @MainActor
    func testSettingsOpensTheNewestEntryAndMarksItSeen() {
        let model = WhatsNewModel(gate: gate(app: "1.1.3"), now: { self.start })
        XCTAssertNotNil(model.bannerEntry)
        XCTAssertEqual(model.openFromSettings()?.version, NotesVersion(major: 1, minor: 1))
        XCTAssertNil(model.bannerEntry)
    }

    @MainActor
    func testSettingsOpensTheSheetAfterTheEntryWasSeen() {
        gate().launchCheck(hadWalletFiles: false)
        let model = WhatsNewModel(gate: gate(), now: { self.start })
        XCTAssertEqual(model.openFromSettings()?.version, NotesVersion(major: 1, minor: 1))
    }

    // MARK: - 30 days

    func testBannerHidesThirtyDaysAfterItFirstShowed() {
        let g = gate()
        let shown = try! XCTUnwrap(g.bannerEntry(now: start))
        g.bannerShown(shown, now: start)
        // A later show keeps the first date.
        g.bannerShown(shown, now: days(10))

        g.homeAppeared(now: days(29))
        XCTAssertNotNil(g.bannerEntry(now: days(29)))
        XCTAssertNil(defaults.string(forKey: WhatsNewGate.lastSeenKey))

        XCTAssertNil(g.bannerEntry(now: days(30)))
        g.homeAppeared(now: days(30))
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.1")
    }

    func testTheClockStartsOnlyWhenTheBannerShows() {
        let g = gate()
        // The banner waited behind an Offline banner for 40 days.
        g.homeAppeared(now: days(40))
        XCTAssertNotNil(g.bannerEntry(now: days(40)))
        XCTAssertNil(defaults.string(forKey: WhatsNewGate.lastSeenKey))
    }

    // MARK: - Later entries

    func testALaterEntryShowsTheBannerAgain() {
        let entries = [entry(1, 1), entry(1, 2)]
        let old = gate(app: "1.1.0", entries: entries)
        let first = try! XCTUnwrap(old.bannerEntry(now: start))
        old.bannerShown(first, now: start)
        // The 1.1 banner was never tapped; then 1.2 arrives 25 days later.
        let new = gate(app: "1.2.0", entries: entries)
        XCTAssertEqual(new.bannerEntry(now: days(25))?.version, NotesVersion(major: 1, minor: 2))
        // The 1.1 date does not count for 1.2.
        XCTAssertNotNil(new.bannerEntry(now: days(35)))
        new.bannerShown(try! XCTUnwrap(new.bannerEntry(now: days(35))), now: days(35))
        XCTAssertNotNil(new.bannerEntry(now: days(64)))
        XCTAssertNil(new.bannerEntry(now: days(65)))
    }

    func testASeenEntryWithALaterOneShowsOnlyTheNewest() {
        defaults.set("1.1", forKey: WhatsNewGate.lastSeenKey)
        let g = gate(app: "1.3.0", entries: [entry(1, 1), entry(1, 2), entry(1, 3)])
        XCTAssertEqual(g.bannerEntry(now: start)?.version, NotesVersion(major: 1, minor: 3))
        g.markSeen(try! XCTUnwrap(g.bannerEntry(now: start)))
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.3")
    }

    func testAPointReleaseWithNoEntryKeepsTheSeenState() {
        defaults.set("1.1", forKey: WhatsNewGate.lastSeenKey)
        XCTAssertNil(gate(app: "1.1.1").bannerEntry(now: start))
    }

    func testMarkingAnOlderEntryNeverLowersTheSeenVersion() {
        defaults.set("1.2", forKey: WhatsNewGate.lastSeenKey)
        gate().markSeen(entry(1, 1))
        XCTAssertEqual(defaults.string(forKey: WhatsNewGate.lastSeenKey), "1.2")
    }

    // MARK: - Versions

    func testVersionsCompareAsNumbers() {
        XCTAssertGreaterThan(NotesVersion(major: 1, minor: 10), NotesVersion(major: 1, minor: 9))
        XCTAssertGreaterThan(NotesVersion(major: 2, minor: 0), NotesVersion(major: 1, minor: 12))
        XCTAssertEqual(NotesVersion("1.10.2"), NotesVersion(major: 1, minor: 10))
        XCTAssertEqual(NotesVersion("1.1"), NotesVersion(major: 1, minor: 1))
        XCTAssertNil(NotesVersion("1"))
        XCTAssertNil(NotesVersion("one.two"))
    }

    func testNewestEntryAtOrBelowTheAppVersion() {
        let entries = [entry(1, 1), entry(1, 10), entry(1, 9)]
        XCTAssertEqual(WhatsNewNotes.newest(in: entries, atOrBelow: NotesVersion("1.10.0"))?.version, NotesVersion(major: 1, minor: 10))
        XCTAssertEqual(WhatsNewNotes.newest(in: entries, atOrBelow: NotesVersion("1.9.4"))?.version, NotesVersion(major: 1, minor: 9))
        XCTAssertEqual(WhatsNewNotes.newest(in: entries, atOrBelow: NotesVersion("1.2.0"))?.version, NotesVersion(major: 1, minor: 1))
        XCTAssertNil(WhatsNewNotes.newest(in: entries, atOrBelow: NotesVersion("1.0.9")))
        XCTAssertNil(WhatsNewNotes.newest(in: entries, atOrBelow: nil))
    }

    func testAnAppWithNoEntryShowsNothing() {
        let g = gate(app: "1.0.9")
        g.launchCheck(hadWalletFiles: false)
        XCTAssertNil(defaults.string(forKey: WhatsNewGate.lastSeenKey))
        XCTAssertNil(g.bannerEntry(now: start))
    }

    func testTheShippedNotesHaveThe11Entry() {
        let notes = WhatsNewNotes.newest(in: WhatsNewNotes.entries, atOrBelow: NotesVersion("1.1.0"))
        XCTAssertEqual(notes?.version, NotesVersion(major: 1, minor: 1))
        XCTAssertEqual(notes?.highlights.map(\.systemImage), ["arrow.left.arrow.right", "link", "person.crop.circle", "at", "key.fill"])
        XCTAssertEqual(notes?.highlights.map(\.scene), [.transfer, .link, .contacts, .name, .seed])
        XCTAssertEqual(notes?.improvements.count, 10)
    }

    // MARK: - Slide-in

    @MainActor
    func testPicturesThatComeIntoViewTogetherStart60msApart() {
        let clock = WhatsNewRevealClock()
        XCTAssertEqual(clock.delay(now: start), 0)
        XCTAssertEqual(clock.delay(now: start), 0.06, accuracy: 0.0001)
        XCTAssertEqual(clock.delay(now: start.addingTimeInterval(0.01)), 0.12, accuracy: 0.0001)
    }

    @MainActor
    func testAPictureScrolledIntoViewLaterStartsAtOnce() {
        let clock = WhatsNewRevealClock()
        _ = clock.delay(now: start)
        _ = clock.delay(now: start)
        XCTAssertEqual(clock.delay(now: start.addingTimeInterval(1)), 0)
    }
}
