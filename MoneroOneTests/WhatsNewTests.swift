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
        XCTAssertEqual(notes?.highlights.map(\.systemImage), ["link", "arrow.left.arrow.right", "person.crop.circle", "at", "key.fill"])
        XCTAssertEqual(notes?.highlights.map(\.scene), [.link, .transfer, .contacts, .name, .seed])
        XCTAssertEqual(notes?.improvements.count, 10)
    }

    // MARK: - Feature cards (Flighty layout)

    func testEachCardIsTheContentWidthAt16To10WithRadius20() {
        // A 402 pt phone: 354 pt of content inside the 24 pt margins.
        XCTAssertEqual(WhatsNewFeatureLayout.cardHeight(width: 354), 221.25, accuracy: 0.001)
        // The readable column caps the content at 480 - 48.
        XCTAssertEqual(WhatsNewFeatureLayout.cardHeight(width: 432), 270, accuracy: 0.001)
        XCTAssertEqual(WhatsNewFeatureLayout.cardCornerRadius, 20)
    }

    func testThePictureFitsInsideTheCardWithItsPadding() {
        let card = CGSize(width: 354, height: WhatsNewFeatureLayout.cardHeight(width: 354))
        let p = WhatsNewFeatureLayout.cardPadding
        let box = CGSize(width: card.width - 2 * p, height: card.height - 2 * p)
        // A tall picture is held by the height.
        let tall = WhatsNewFeatureLayout.pictureScale(native: CGSize(width: 370, height: 260), fill: 1, in: box)
        XCTAssertEqual(tall, box.height / 260, accuracy: 0.0001)
        // A wide picture is held by the width share.
        let wide = WhatsNewFeatureLayout.pictureScale(native: CGSize(width: 300, height: 60), fill: 0.5, in: box)
        XCTAssertEqual(wide, box.width * 0.5 / 300, accuracy: 0.0001)
        // Only a width: the picture takes its share of it.
        let open = WhatsNewFeatureLayout.pictureScale(
            native: CGSize(width: 300, height: 200), fill: 1, in: CGSize(width: 150, height: CGFloat.infinity)
        )
        XCTAssertEqual(open, 0.5, accuracy: 0.0001)
    }

    func testTheTextLinesUpWithTheCardsInnerEdgeAndTheRhythmIsEven() {
        XCTAssertEqual(WhatsNewFeatureLayout.textInset, 12)
        XCTAssertEqual(WhatsNewFeatureLayout.cardToText, 16)
        XCTAssertEqual(WhatsNewFeatureLayout.rowSpacing, 40)
    }

    func testTheXIsA44PointTargetAtTheTopTrailingCorner() {
        XCTAssertEqual(WhatsNewFeatureLayout.closeSize, 44)
        XCTAssertEqual(WhatsNewFeatureLayout.closeInset, 16)
    }

    // MARK: - The Transfer loop (top card)

    func testTheTransferLoopPressesShowsTheAmountThenMovesIt() {
        typealias Loop = WhatsNewTransferLoop
        XCTAssertEqual(Loop.Step.allCases, [.start, .press, .amount, .sent, .received, .fade])
        XCTAssertEqual(Loop.Step.allCases.map(Loop.buttonScale(at:)), [1, Loop.pressScale, 1, 1, 1, 1])
        XCTAssertLessThan(Loop.pressScale, 1)
        XCTAssertEqual(Loop.Step.allCases.map(Loop.showsAmount(at:)), [false, false, true, true, true, false])
        XCTAssertEqual(Loop.Step.allCases.map(Loop.pictureOpacity(at:)), [1, 1, 1, 1, 1, 0])
        // From rolls down first, then To rolls up.
        XCTAssertEqual(Loop.Step.allCases.map(Loop.fromBalance(at:)), [
            Loop.fromBalance, Loop.fromBalance, Loop.fromBalance,
            Loop.fromBalance - Loop.amount, Loop.fromBalance - Loop.amount, Loop.fromBalance - Loop.amount,
        ])
        XCTAssertEqual(Loop.Step.allCases.map(Loop.toBalance(at:)), [
            Loop.toBalance, Loop.toBalance, Loop.toBalance, Loop.toBalance,
            Loop.toBalance + Loop.amount, Loop.toBalance + Loop.amount,
        ])
        XCTAssertEqual(Loop.fromBalance(at: .received), Decimal(string: "1034.503917"))
        XCTAssertEqual(Loop.toBalance(at: .received), Decimal(string: "250.25"))
    }

    func testTheTransferLoopEndsWithTheSameTotal() {
        typealias Loop = WhatsNewTransferLoop
        let total = Loop.fromBalance + Loop.toBalance
        XCTAssertEqual(Loop.fromBalance(at: .start) + Loop.toBalance(at: .start), total)
        XCTAssertEqual(Loop.fromBalance(at: .received) + Loop.toBalance(at: .received), total)
    }

    func testTheTransferLoopRunsAboutFiveSecondsWithRests() {
        typealias Loop = WhatsNewTransferLoop
        XCTAssertEqual(Loop.cycleDuration, 5.9, accuracy: 0.001)
        XCTAssertTrue((4...6).contains(Loop.cycleDuration))
        // The rests: on the result before the way back, on the start frame
        // before the press.
        XCTAssertEqual(Loop.delay(before: .fade), 2.0)
        XCTAssertEqual(Loop.delay(before: .press), 1.4)
        // Each step begins after the one before it has finished.
        let begins = Loop.Step.allCases.map(Loop.begin(of:))
        XCTAssertEqual(begins.count, 6)
        for (index, expected) in [0, 1.75, 1.85, 2.85, 3.35, 5.55].enumerated() {
            XCTAssertEqual(begins[index], expected, accuracy: 0.001)
        }
        // The step at a time: on a begin it is that step; the cycle wraps.
        XCTAssertEqual(Loop.step(at: 0), .start)
        XCTAssertEqual(Loop.step(at: 1.75), .press)
        XCTAssertEqual(Loop.step(at: 2.0), .amount)
        XCTAssertEqual(Loop.step(at: 3.35), .received)
        XCTAssertEqual(Loop.step(at: 5.6), .fade)
        XCTAssertEqual(Loop.step(at: Loop.cycleDuration), .start)
        XCTAssertEqual(Loop.step(at: Loop.cycleDuration + 1.75), .press)
        // The motion tokens: crossFade 0.35, press 0.1, settle 0.4,
        // rollDigits 0.2. No move takes longer than 0.5 s.
        XCTAssertEqual(Loop.Step.allCases.map(Loop.duration(of:)), [0.35, 0.1, 0.4, 0.2, 0.2, 0.35])
        XCTAssertTrue(Loop.Step.allCases.allSatisfy { Loop.duration(of: $0) <= 0.5 })
    }

    func testReduceMotionShowsTheLoopsLastFrameStill() {
        typealias Loop = WhatsNewTransferLoop
        // The result: the last frame before the fade.
        XCTAssertEqual(Loop.stillStep, .received)
        XCTAssertEqual(Loop.pictureOpacity(at: Loop.stillStep), 1)
        XCTAssertTrue(Loop.showsAmount(at: Loop.stillStep))
        XCTAssertEqual(Loop.buttonScale(at: Loop.stillStep), 1)
        XCTAssertEqual(Loop.fromBalance(at: Loop.stillStep), Loop.fromBalance - Loop.amount)
        XCTAssertEqual(Loop.toBalance(at: Loop.stillStep), Loop.toBalance + Loop.amount)
    }

    // MARK: - The envelope loop (the send's stamp)

    func testTheEnvelopeLoopPlaysTheSendsStampInOrder() {
        typealias Loop = WhatsNewLinkLoop
        let hero = PaymentLinkSendHero.self
        XCTAssertEqual(Loop.Step.allCases, [.start, .drop, .hover, .press, .contact, .lift, .mark, .away, .sweep, .fade])
        // The start: the closed envelope, no seal, no stamp, no foil.
        let start = Loop.frame(at: .start)
        XCTAssertEqual(start, Loop.Frame())
        XCTAssertEqual(start.sealShown, 0)
        XCTAssertEqual(start.sealScale, Loop.dropStartScale)
        XCTAssertEqual(start.toolShown, 0)
        XCTAssertEqual(start.toolOffset, hero.toolAway)
        XCTAssertEqual(start.sweep, Envelope.sweepStart)
        XCTAssertEqual(start.opacity, 1)
        // Each step changes only what the hero changes at that beat.
        var expected = start
        expected.sealShown = 1
        expected.sealScale = hero.dropScale
        XCTAssertEqual(Loop.frame(at: .drop), expected)
        expected.toolShown = 1
        expected.toolOffset = CGSize(width: 0, height: hero.toolHover)
        expected.toolTilt = 0
        XCTAssertEqual(Loop.frame(at: .hover), expected)
        expected.toolOffset.height = hero.toolSink
        expected.toolHeight = 0
        XCTAssertEqual(Loop.frame(at: .press), expected)
        expected.sealScale = 1
        expected.sealDome = 0
        XCTAssertEqual(Loop.frame(at: .contact), expected)
        expected.toolOffset.height = hero.toolSink - hero.toolLift
        expected.toolHeight = 1
        XCTAssertEqual(Loop.frame(at: .lift), expected)
        expected.sealMark = 1
        XCTAssertEqual(Loop.frame(at: .mark), expected)
        expected.toolShown = 0
        expected.toolOffset = hero.toolAway
        expected.toolTilt = hero.toolTilt
        XCTAssertEqual(Loop.frame(at: .away), expected)
        expected.sweep = Envelope.sweepEnd
        XCTAssertEqual(Loop.frame(at: .sweep), expected)
        expected.opacity = 0
        XCTAssertEqual(Loop.frame(at: .fade), expected)
        // The stamp shows from the hover until it goes; the picture is
        // clear only on the fade.
        XCTAssertEqual(Loop.Step.allCases.map { Loop.frame(at: $0).toolShown }, [0, 0, 1, 1, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(Loop.Step.allCases.map { Loop.frame(at: $0).opacity }, [1, 1, 1, 1, 1, 1, 1, 1, 1, 0])
    }

    func testTheEnvelopeLoopKeepsTheHerosTimingWithRests() {
        typealias Loop = WhatsNewLinkLoop
        XCTAssertEqual(PaymentLinkSendHero.pace, 1.3)
        // The hero's beats from the wax to the sweep (pace 1), at its pace.
        let beats: [(Loop.Step, Double)] = [
            (.drop, 2.10), (.hover, 2.25), (.press, 2.65), (.contact, 2.74),
            (.lift, 2.90), (.mark, 2.93), (.away, 3.00), (.sweep, 3.10),
        ]
        for (step, beat) in beats {
            XCTAssertEqual(Loop.begin(of: step) - Loop.begin(of: .drop), (beat - 2.10) * 1.3, accuracy: 0.0001)
        }
        // The fade-in and a rest before the wax; the sweep and a rest on the
        // sealed envelope before the fade; one cycle of 5.8 s.
        XCTAssertEqual(Loop.begin(of: .drop), 0.35 + 0.6, accuracy: 0.0001)
        XCTAssertEqual(Loop.begin(of: .fade) - Loop.begin(of: .sweep), 1.2 + 2.0, accuracy: 0.0001)
        XCTAssertEqual(Loop.cycleDuration, 5.8, accuracy: 0.001)
        XCTAssertTrue((4...6).contains(Loop.cycleDuration))
        let begins = Loop.Step.allCases.map(Loop.begin(of:))
        XCTAssertEqual(begins, begins.sorted())
        XCTAssertEqual(Set(begins).count, begins.count)
        // The step at a time: on a begin it is that step; the cycle wraps.
        XCTAssertEqual(Loop.step(at: 0), .start)
        XCTAssertEqual(Loop.step(at: 0.95), .drop)
        XCTAssertEqual(Loop.step(at: Loop.begin(of: .press)), .press)
        XCTAssertEqual(Loop.step(at: Loop.begin(of: .contact)), .contact)
        XCTAssertEqual(Loop.step(at: 5.5), .fade)
        XCTAssertEqual(Loop.step(at: Loop.cycleDuration), .start)
        XCTAssertEqual(Loop.step(at: Loop.cycleDuration + 0.95), .drop)
    }

    func testReduceMotionShowsTheSealedEnvelopeStill() {
        typealias Loop = WhatsNewLinkLoop
        // The hero's end, the last frame before the fade: the seal pressed
        // with its ring and mark, the foil shown, the stamp gone.
        XCTAssertEqual(Loop.stillStep, .sweep)
        let order = Loop.Step.allCases
        XCTAssertEqual(order.firstIndex(of: .fade), order.firstIndex(of: Loop.stillStep).map { $0 + 1 })
        let still = Loop.frame(at: Loop.stillStep)
        XCTAssertEqual(still.sealShown, 1)
        XCTAssertEqual(still.sealScale, 1)
        XCTAssertEqual(still.sealMark, 1)
        XCTAssertEqual(still.sealDome, 0)
        XCTAssertEqual(still.toolShown, 0)
        XCTAssertEqual(still.sweep, Envelope.sweepEnd)
        XCTAssertEqual(still.opacity, 1)
    }

    // MARK: - Links

    func testShareWithFriendsSharesTheWebsite() {
        XCTAssertEqual(WhatsNewLinks.share.absoluteString, "https://monero.one/download")
    }

    func testRateOpensTheAppStoreWriteReviewPage() {
        XCTAssertEqual(
            WhatsNewLinks.rate.absoluteString,
            "https://apps.apple.com/app/id6757898541?action=write-review"
        )
    }
}
