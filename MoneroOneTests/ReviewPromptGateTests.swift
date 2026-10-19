import XCTest
@testable import MoneroOne

/// Apple's review prompt after the first successful send: once per install,
/// only on an idle wallet home, never after an error, never after the person
/// rated from Settings.
final class ReviewPromptGateTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ReviewPromptGateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private var gate: ReviewPromptGate { ReviewPromptGate(defaults: defaults) }

    func testNothingPendingBeforeASend() {
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.claim(homeIsIdle: true))
    }

    func testSuccessfulSendStaysPendingUntilTheHomeIsIdle() {
        gate.sendPhaseChanged(to: .success(txHash: "abc"))
        XCTAssertTrue(gate.isPending)

        // The send sheet is still open, or the home is not on screen.
        XCTAssertFalse(gate.claim(homeIsIdle: false))
        XCTAssertTrue(gate.isPending)

        XCTAssertTrue(gate.claim(homeIsIdle: true))
        XCTAssertTrue(gate.isDone)
        XCTAssertFalse(gate.isPending)
    }

    func testPendingSurvivesARelaunch() {
        ReviewPromptGate(defaults: defaults).sendPhaseChanged(to: .success(txHash: "abc"))
        // A new gate reads the same store, as after the app was closed.
        XCTAssertTrue(ReviewPromptGate(defaults: defaults).claim(homeIsIdle: true))
    }

    func testFiresOnceOnly() {
        gate.sendPhaseChanged(to: .success(txHash: "first"))
        XCTAssertTrue(gate.claim(homeIsIdle: true))

        gate.sendPhaseChanged(to: .success(txHash: "second"))
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.claim(homeIsIdle: true))
    }

    func testRatingFromSettingsBeforeASendSuppressesIt() {
        gate.ratedFromSettings()
        gate.sendPhaseChanged(to: .success(txHash: "abc"))
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.claim(homeIsIdle: true))
    }

    func testRatingFromSettingsClearsAPendingPrompt() {
        gate.sendPhaseChanged(to: .success(txHash: "abc"))
        gate.ratedFromSettings()
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.claim(homeIsIdle: true))
    }

    func testErrorAndOtherPhasesDoNotSetIt() {
        let phases: [SendFlowPhase] = [.address, .amount, .review, .sending, .error(message: "Broadcast failed")]
        for phase in phases {
            gate.sendPhaseChanged(to: phase)
            XCTAssertFalse(gate.isPending, "\(phase) must not set the prompt")
        }
        XCTAssertFalse(gate.claim(homeIsIdle: true))
    }
}
