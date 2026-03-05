import XCTest

enum UITestHelpers {
    /// Launch the app with clean state (UserDefaults and Keychain cleared)
    static func launchCleanApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-state"]
        app.launch()
        return app
    }

    /// Accept all disclaimer checkboxes and tap the accept button
    static func acceptDisclaimer(app: XCUIApplication) {
        for i in 0..<5 {
            let checkbox = app.buttons["disclaimer.checkbox.\(i)"]
            if checkbox.waitForExistence(timeout: 3) {
                checkbox.tap()
            }
        }
        let acceptButton = app.buttons["disclaimer.acceptButton"]
        XCTAssertTrue(acceptButton.waitForExistence(timeout: 3))
        acceptButton.tap()
    }

    /// Navigate past disclaimer to the welcome screen
    static func navigateToWelcome(app: XCUIApplication) {
        acceptDisclaimer(app: app)
        let createButton = app.buttons["welcome.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Should reach welcome screen")
    }

    /// Navigate to the create wallet seed type step
    static func navigateToCreateSeedType(app: XCUIApplication) {
        navigateToWelcome(app: app)
        app.buttons["welcome.createButton"].tap()
    }

    /// Navigate to the create wallet PIN step (generates wallet, lands on PIN entry)
    static func navigateToCreatePIN(app: XCUIApplication) {
        navigateToCreateSeedType(app: app)
        let continueButton = app.buttons["create.seedType.continueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
    }

    /// Type a PIN into a PINEntryView/PINEntryFieldView identified by its accessibility ID
    static func enterPIN(app: XCUIApplication, identifier: String, pin: String) {
        let textField = app.textFields[identifier]
        if textField.waitForExistence(timeout: 3) {
            textField.tap()
            textField.typeText(pin)
        }
    }

    /// Navigate to the restore wallet seed entry step
    static func navigateToRestoreSeed(app: XCUIApplication) {
        navigateToWelcome(app: app)
        app.buttons["welcome.restoreButton"].tap()
    }
}
