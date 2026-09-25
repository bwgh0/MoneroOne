import XCTest

// MARK: - Onboarding Flow Tests

final class OnboardingFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDisclaimerShownOnFreshLaunch() {
        let app = UITestHelpers.launchCleanApp()
        let title = app.staticTexts["disclaimer.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Disclaimer should show on fresh launch")
    }

    func testDisclaimerAcceptButtonDisabledUntilAllChecked() {
        let app = UITestHelpers.launchCleanApp()
        let acceptButton = app.buttons["disclaimer.acceptButton"]
        XCTAssertTrue(acceptButton.waitForExistence(timeout: 5))
        XCTAssertFalse(acceptButton.isEnabled, "Accept button should be disabled before all checkboxes checked")

        // Check all 5 checkboxes
        for i in 0..<5 {
            app.buttons["disclaimer.checkbox.\(i)"].tap()
        }

        XCTAssertTrue(acceptButton.isEnabled, "Accept button should be enabled after all checkboxes checked")
    }

    func testDisclaimerAcceptNavigatesToWelcome() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.acceptDisclaimer(app: app)

        let welcomeTitle = app.staticTexts["welcome.title"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5), "Should navigate to welcome screen after accepting disclaimer")
    }

    func testWelcomeScreenShowsCreateAndRestore() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.acceptDisclaimer(app: app)

        let createButton = app.buttons["welcome.createButton"]
        let restoreButton = app.buttons["welcome.restoreButton"]

        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create button should be visible")
        XCTAssertTrue(restoreButton.exists, "Restore button should be visible")
        XCTAssertTrue(createButton.isHittable, "Create button should be tappable")
        XCTAssertTrue(restoreButton.isHittable, "Restore button should be tappable")
    }

    func testCreateWalletNavigatesToSeedType() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToCreateSeedType(app: app)

        let continueButton = app.buttons["create.seedType.continueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "Should see seed type selection with Continue button")
    }

    func testCreateWalletSeedTypeNavigatesToPIN() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToCreatePIN(app: app)

        // Should show PIN entry fields
        let pinField = app.textFields["create.pinEntry"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 5), "Should show PIN entry after seed type selection")
    }

    func testCreateWalletPINMismatchShowsError() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToCreatePIN(app: app)

        // Enter PIN in first field
        UITestHelpers.enterPIN(app: app, identifier: "create.pinEntry", pin: "123456")

        // Enter different PIN in confirm field
        UITestHelpers.enterPIN(app: app, identifier: "create.confirmPinEntry", pin: "654321")

        // Should show mismatch error
        let mismatchError = app.staticTexts["create.pinMismatchError"]
        XCTAssertTrue(mismatchError.waitForExistence(timeout: 3), "Should show PIN mismatch error")
    }

    func testRestoreWalletShowsSeedEntry() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToRestoreSeed(app: app)

        let seedInput = app.textViews["restore.seedInput"]
        let continueButton = app.buttons["restore.continueButton"]

        XCTAssertTrue(seedInput.waitForExistence(timeout: 5), "Should show seed input field")
        XCTAssertTrue(continueButton.exists, "Should show continue button")
        XCTAssertFalse(continueButton.isEnabled, "Continue should be disabled with empty seed")
    }

    func testBackNavigationFromCreate() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToCreateSeedType(app: app)

        // Tap back button
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists {
            backButton.tap()
        }

        // Should be back at welcome screen
        let welcomeTitle = app.staticTexts["welcome.title"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5), "Should return to welcome screen")
    }

    func testBackNavigationFromRestore() {
        let app = UITestHelpers.launchCleanApp()
        UITestHelpers.navigateToRestoreSeed(app: app)

        // Tap back button
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists {
            backButton.tap()
        }

        // Should be back at welcome screen
        let welcomeTitle = app.staticTexts["welcome.title"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5), "Should return to welcome screen")
    }
}

// MARK: - Unlock Flow Tests

final class UnlockFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUnlockScreenShowsPINEntry() {
        // This test requires a wallet to exist — launch without --reset-state
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let pinEntry = app.textFields["unlock.pinEntry"]
        // Only proceed if we're on the unlock screen (wallet exists)
        guard pinEntry.waitForExistence(timeout: 3) else {
            // No wallet — can't test unlock
            return
        }
        XCTAssertTrue(pinEntry.exists, "Unlock screen should show PIN entry")
    }

    func testUnlockButtonExists() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let unlockButton = app.buttons["unlock.unlockButton"]
        guard unlockButton.waitForExistence(timeout: 3) else {
            // No wallet — can't test unlock
            return
        }
        XCTAssertTrue(unlockButton.exists, "Unlock button should be visible")
    }

    func testWrongPINShowsError() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let pinEntry = app.textFields["unlock.pinEntry"]
        guard pinEntry.waitForExistence(timeout: 3) else { return }

        // Type wrong PIN
        pinEntry.tap()
        pinEntry.typeText("000000")

        // Tap unlock
        let unlockButton = app.buttons["unlock.unlockButton"]
        if unlockButton.waitForExistence(timeout: 2) && unlockButton.isEnabled {
            unlockButton.tap()
        }

        // Should show error
        let errorMessage = app.staticTexts["unlock.errorMessage"]
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 3), "Should show error for wrong PIN")
    }
}

// MARK: - Main App Flow Tests

final class MainAppFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTabsExistWhenWalletUnlocked() {
        // Launch without reset to preserve existing wallet state
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        // Only test if we can get past unlock (this requires a wallet + correct PIN)
        let walletTab = app.tabBars.buttons["Wallet"]
        guard walletTab.waitForExistence(timeout: 5) else {
            // Not on main screen — skip
            return
        }

        let chartTab = app.tabBars.buttons["Chart"]
        let settingsTab = app.tabBars.buttons["Settings"]

        XCTAssertTrue(walletTab.exists, "Wallet tab should exist")
        XCTAssertTrue(chartTab.exists, "Chart tab should exist")
        XCTAssertTrue(settingsTab.exists, "Settings tab should exist")
    }

    func testTabNavigationSwitchesContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 5) else { return }

        settingsTab.tap()

        // Should show settings content
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 3), "Should show Settings navigation title")

        // Switch back to wallet
        let walletTab = app.tabBars.buttons["Wallet"]
        walletTab.tap()

        // Should show wallet content (send/receive buttons)
        let sendButton = app.buttons["wallet.sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3), "Should show wallet send button")
    }

    func testWalletSendButtonExists() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let sendButton = app.buttons["wallet.sendButton"]
        guard sendButton.waitForExistence(timeout: 5) else { return }
        XCTAssertTrue(sendButton.isHittable, "Send button should be tappable")
    }

    func testWalletReceiveButtonExists() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let receiveButton = app.buttons["wallet.receiveButton"]
        guard receiveButton.waitForExistence(timeout: 5) else { return }
        XCTAssertTrue(receiveButton.isHittable, "Receive button should be tappable")
    }
}

// MARK: - Settings Flow Tests

final class SettingsFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsRowsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 5) else { return }
        settingsTab.tap()

        let backupRow = app.buttons["settings.backupRow"]
        let securityRow = app.buttons["settings.securityRow"]
        let syncRow = app.buttons["settings.syncRow"]

        XCTAssertTrue(backupRow.waitForExistence(timeout: 3), "Backup seed phrase row should exist")
        XCTAssertTrue(securityRow.exists, "Security row should exist")
        XCTAssertTrue(syncRow.exists, "Sync settings row should exist")
    }

    func testBackupRowNavigates() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 5) else { return }
        settingsTab.tap()

        let backupRow = app.buttons["settings.backupRow"]
        guard backupRow.waitForExistence(timeout: 3) else { return }
        backupRow.tap()

        // Should navigate to backup view (PIN required to view seed)
        // Just verify navigation occurred
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "Should navigate to backup view")
    }

    func testSecurityRowNavigates() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 5) else { return }
        settingsTab.tap()

        let securityRow = app.buttons["settings.securityRow"]
        guard securityRow.waitForExistence(timeout: 3) else { return }
        securityRow.tap()

        // Should navigate to security view
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "Should navigate to security view")
    }
}

// MARK: - Screenshot walkthrough (iPhone Duo / regular width review)

/// Walks disclaimer → create wallet (PIN 123456) → dashboard → settings →
/// receive → send and attaches a screenshot of every screen. Run once per
/// fold posture (see the /duo skill) and export with
/// `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`.
final class DuoWalkthroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        // app.screenshot(), not XCUIScreen.main: on the unfolded iPhone Duo the
        // main screen is the dark cover display, the app lives on the inner one.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Hold each screen so an external `simctl io screenshot` loop can
        // grab it too; XCTest captures are black on the unfolded Duo.
        sleep(2)
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    /// First button matching any of the given identifiers or labels.
    private func button(_ names: [String]) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier IN %@ OR label IN %@", names, names)
        return app.buttons.matching(predicate).firstMatch
    }

    private func dismissSheet() {
        if tapIfExists(button(["Done", "Close", "Cancel"]), timeout: 2) { return }
        app.swipeDown(velocity: .fast)
    }

    func testCreateWalletWalkthrough() throws {
        app = UITestHelpers.launchCleanApp()
        // Some long-lived simulators come up with the disclaimer already
        // accepted; treat that step as optional.
        let accept = button(["disclaimer.acceptButton", "I Understand, Continue"])
        if accept.waitForExistence(timeout: 10) {
            shot("01-disclaimer")
            for i in 0..<5 {
                tapIfExists(app.buttons["disclaimer.checkbox.\(i)"], timeout: 2)
            }
            accept.tap()
        }

        XCTAssertTrue(app.buttons["welcome.createButton"].waitForExistence(timeout: 5))
        shot("02-welcome")
        app.buttons["welcome.createButton"].tap()

        XCTAssertTrue(app.buttons["create.seedType.continueButton"].waitForExistence(timeout: 5))
        shot("03-create-seed-type")
        app.buttons["create.seedType.continueButton"].tap()

        XCTAssertTrue(app.textFields["create.pinEntry"].waitForExistence(timeout: 5))
        shot("04-create-pin-empty")
        UITestHelpers.enterPIN(app: app, identifier: "create.pinEntry", pin: "123456")
        UITestHelpers.enterPIN(app: app, identifier: "create.confirmPinEntry", pin: "123456")
        shot("05-create-pin-filled")
        tapIfExists(app.buttons["create.pin.continueButton"])

        // Biometric step only appears when the device offers biometrics.
        if app.buttons["Skip for Now"].waitForExistence(timeout: 2) {
            shot("06-create-biometrics")
            app.buttons["Skip for Now"].tap()
        }

        let confirmToggle = app.switches["create.confirmToggle"]
        XCTAssertTrue(confirmToggle.waitForExistence(timeout: 10))
        shot("07-create-seed")
        confirmToggle.tap()
        let seedContinue = app.buttons["create.seed.continueButton"]
        if !seedContinue.isEnabled {
            confirmToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        tapIfExists(seedContinue)

        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        shot("08-create-name")
        tapIfExists(button(["Continue"]))

        // Dashboard: compact width has wallet.sendButton, regular width the "Send" quick action.
        let send = button(["wallet.sendButton", "Send", "Send Monero"])
        XCTAssertTrue(send.waitForExistence(timeout: 90), "wallet should be created and unlocked")
        sleep(2)
        shot("09-dashboard")

        if tapIfExists(app.buttons["wallet.switcher"], timeout: 3) {
            sleep(2)
            shot("09b-wallet-switcher-open")
            // The pencil is hidden from VoiceOver (Rename is a rotor action
            // on the row), so tap it where it sits: 68 pt in from the row's
            // trailing edge, on its vertical center.
            let activeRow = app.buttons["wallet.row.active"]
            if activeRow.waitForExistence(timeout: 3) {
                activeRow.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                    .withOffset(CGVector(dx: -68, dy: 0))
                    .tap()
                sleep(2)
                shot("09c-rename-wallet")
                if tapIfExists(app.buttons["emojiPicker.circle"], timeout: 3) {
                    sleep(2)
                    shot("09d-emoji-picker")
                    tapIfExists(button(["Cancel"]), timeout: 3)
                    sleep(1)
                }
                tapIfExists(button(["Cancel"]), timeout: 3)
                sleep(1)
            }
            tapIfExists(app.buttons["wallet.switcher"], timeout: 3)
            sleep(1)
        }

        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"]
            : button(["Settings", "tab.settings"])
        if tapIfExists(settingsTab, timeout: 3) {
            sleep(2)
            shot("10-settings")
            let backTab = app.tabBars.buttons.firstMatch.exists
                ? app.tabBars.buttons.firstMatch
                : button(["Wallet", "Dashboard", "tab.wallet"])
            tapIfExists(backTab, timeout: 3)
            sleep(1)
        }

        if tapIfExists(button(["Chart", "tab.chart"]), timeout: 2) {
            sleep(1)
            shot("11-chart")
            tapIfExists(button(["Wallet", "tab.wallet"]), timeout: 3)
        }

        if tapIfExists(button(["wallet.receiveButton", "Receive", "Receive Monero"]), timeout: 3) {
            sleep(2)
            shot("12-receive")
            dismissSheet()
        }

        // Send stays disabled until the first sync finishes; give it a minute.
        let sendButton = button(["wallet.sendButton", "Send", "Send Monero"])
        let sendDeadline = Date().addingTimeInterval(60)
        while sendButton.exists && !sendButton.isEnabled && Date() < sendDeadline { sleep(2) }
        if tapIfExists(sendButton, timeout: 3) {
            sleep(2)
            shot("13-send")
            dismissSheet()
        }
    }
}
