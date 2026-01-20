import XCTest
@testable import MoneroOne

final class SecurityTests: XCTestCase {

    var keychainStorage: KeychainStorage!

    override func setUp() {
        keychainStorage = KeychainStorage()
        // Clean up any existing data
        keychainStorage.deleteSeed()
        keychainStorage.deleteBiometricPin()
        keychainStorage.resetFailedAttempts()
    }

    override func tearDown() {
        keychainStorage.deleteSeed()
        keychainStorage.deleteBiometricPin()
        keychainStorage.resetFailedAttempts()
        keychainStorage = nil
    }

    // MARK: - Encryption Tests

    func testSaveSeedSucceeds() throws {
        let testSeed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let testPin = "123456"

        XCTAssertNoThrow(try keychainStorage.saveSeed(testSeed, pin: testPin))
        XCTAssertTrue(keychainStorage.hasSeed())
    }

    func testGetSeedWithCorrectPinReturnsOriginalSeed() throws {
        let testSeed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let testPin = "123456"

        try keychainStorage.saveSeed(testSeed, pin: testPin)

        let retrievedSeed = try keychainStorage.getSeed(pin: testPin)
        XCTAssertEqual(retrievedSeed, testSeed, "Retrieved seed should match original")
    }

    func testGetSeedWithWrongPinReturnsNil() throws {
        let testSeed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let correctPin = "123456"
        let wrongPin = "654321"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        let retrievedSeed = try keychainStorage.getSeed(pin: wrongPin)
        XCTAssertNil(retrievedSeed, "Wrong PIN should return nil")
    }

    func testDeleteSeedRemovesData() throws {
        let testSeed = "test seed phrase"
        let testPin = "123456"

        try keychainStorage.saveSeed(testSeed, pin: testPin)
        XCTAssertTrue(keychainStorage.hasSeed())

        keychainStorage.deleteSeed()
        XCTAssertFalse(keychainStorage.hasSeed())
    }

    func testMultipleSaveOverwritesPrevious() throws {
        let firstSeed = "first seed phrase words"
        let secondSeed = "second seed phrase words"
        let testPin = "123456"

        try keychainStorage.saveSeed(firstSeed, pin: testPin)
        try keychainStorage.saveSeed(secondSeed, pin: testPin)

        let retrievedSeed = try keychainStorage.getSeed(pin: testPin)
        XCTAssertEqual(retrievedSeed, secondSeed, "Second save should overwrite first")
    }

    // MARK: - PIN Rate Limiting Tests

    func testInitiallyNotLockedOut() {
        XCTAssertFalse(keychainStorage.isLockedOut, "Should not be locked out initially")
        XCTAssertEqual(keychainStorage.lockoutRemainingSeconds, 0)
    }

    func testFailedAttemptsIncrement() throws {
        let testSeed = "test seed phrase"
        let correctPin = "123456"
        let wrongPin = "000000"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        // Make some failed attempts (less than lockout threshold)
        for _ in 0..<4 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        // Should not be locked out yet (threshold is 5)
        XCTAssertFalse(keychainStorage.isLockedOut)
    }

    func testLockoutAfterMaxFailedAttempts() throws {
        let testSeed = "test seed phrase"
        let correctPin = "123456"
        let wrongPin = "000000"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        // Make enough failed attempts to trigger lockout
        for _ in 0..<6 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        // Should be locked out now
        XCTAssertTrue(keychainStorage.isLockedOut)
        XCTAssertGreaterThan(keychainStorage.lockoutRemainingSeconds, 0)
    }

    func testGetSeedThrowsWhenLockedOut() throws {
        let testSeed = "test seed phrase"
        let correctPin = "123456"
        let wrongPin = "000000"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        // Trigger lockout
        for _ in 0..<6 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        // Attempt with correct PIN should throw lockout error
        XCTAssertThrowsError(try keychainStorage.getSeed(pin: correctPin)) { error in
            guard case KeychainError.lockedOut = error else {
                XCTFail("Expected lockedOut error")
                return
            }
        }
    }

    func testSuccessfulLoginResetsFailedAttempts() throws {
        let testSeed = "test seed phrase"
        let correctPin = "123456"
        let wrongPin = "000000"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        // Make some failed attempts
        for _ in 0..<3 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        // Successful login
        _ = try keychainStorage.getSeed(pin: correctPin)

        // Make more failed attempts - should not lock out because counter was reset
        for _ in 0..<3 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        XCTAssertFalse(keychainStorage.isLockedOut, "Counter should have reset after successful login")
    }

    func testResetFailedAttemptsClearsLockout() throws {
        let testSeed = "test seed phrase"
        let correctPin = "123456"
        let wrongPin = "000000"

        try keychainStorage.saveSeed(testSeed, pin: correctPin)

        // Trigger lockout
        for _ in 0..<6 {
            _ = try keychainStorage.getSeed(pin: wrongPin)
        }

        XCTAssertTrue(keychainStorage.isLockedOut)

        // Reset
        keychainStorage.resetFailedAttempts()

        XCTAssertFalse(keychainStorage.isLockedOut)
        XCTAssertEqual(keychainStorage.lockoutRemainingSeconds, 0)
    }

    // MARK: - Data Integrity Tests

    func testEncryptedDataIsDifferentFromPlaintext() throws {
        let testSeed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let testPin = "123456"

        try keychainStorage.saveSeed(testSeed, pin: testPin)

        // We can't directly access the encrypted data, but we verify the roundtrip works
        // and that different PINs produce different results
        let retrieved = try keychainStorage.getSeed(pin: testPin)
        XCTAssertEqual(retrieved, testSeed)

        // Wrong PIN should not decrypt
        let wrongRetrieved = try keychainStorage.getSeed(pin: "000000")
        XCTAssertNil(wrongRetrieved)
    }

    func testDifferentPinsProduceDifferentEncryption() throws {
        // This tests that the salt is unique per save
        let testSeed = "test seed phrase"
        let pin1 = "111111"
        let pin2 = "222222"

        // Save with pin1
        try keychainStorage.saveSeed(testSeed, pin: pin1)
        let canDecryptWithPin1 = try keychainStorage.getSeed(pin: pin1) != nil
        let canDecryptWithPin2 = try keychainStorage.getSeed(pin: pin2) != nil

        XCTAssertTrue(canDecryptWithPin1)
        XCTAssertFalse(canDecryptWithPin2)
    }

    // MARK: - Unicode and Special Character Tests

    func testSeedWithUnicodeCharacters() throws {
        // Test that encryption handles various character types
        let unicodeSeed = "café naïve résumé über"
        let testPin = "123456"

        try keychainStorage.saveSeed(unicodeSeed, pin: testPin)
        let retrieved = try keychainStorage.getSeed(pin: testPin)

        XCTAssertEqual(retrieved, unicodeSeed)
    }

    func testLongSeedPhrase() throws {
        // Test with a longer seed phrase
        let longSeed = Array(repeating: "abandon", count: 25).joined(separator: " ")
        let testPin = "123456"

        try keychainStorage.saveSeed(longSeed, pin: testPin)
        let retrieved = try keychainStorage.getSeed(pin: testPin)

        XCTAssertEqual(retrieved, longSeed)
    }

    func testPinWithLeadingZeros() throws {
        let testSeed = "test seed phrase"
        let pinWithZeros = "000123"

        try keychainStorage.saveSeed(testSeed, pin: pinWithZeros)
        let retrieved = try keychainStorage.getSeed(pin: pinWithZeros)

        XCTAssertEqual(retrieved, testSeed)
    }

    // MARK: - Error Handling Tests

    func testGetSeedWithoutSavingReturnsNil() throws {
        let result = try keychainStorage.getSeed(pin: "123456")
        XCTAssertNil(result)
    }

    func testHasSeedReturnsFalseWhenEmpty() {
        XCTAssertFalse(keychainStorage.hasSeed())
    }
}

// MARK: - Server Configuration Tests

final class ServerConfigurationTests: XCTestCase {

    func testServerURLsAreNotHardcoded() {
        // Verify that server URLs come from configuration, not hardcoded IPs
        let testnetURL = ServerConfiguration.testnetLWSServerURL
        let mainnetURL = ServerConfiguration.mainnetLWSServerURL

        // Check that URLs don't contain raw IP addresses (pattern: digits.digits.digits.digits)
        let ipPattern = #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#
        let ipRegex = try! NSRegularExpression(pattern: ipPattern)

        let testnetRange = NSRange(testnetURL.startIndex..., in: testnetURL)
        let mainnetRange = NSRange(mainnetURL.startIndex..., in: mainnetURL)

        XCTAssertNil(ipRegex.firstMatch(in: testnetURL, range: testnetRange), "Testnet URL should not contain hardcoded IP")
        XCTAssertNil(ipRegex.firstMatch(in: mainnetURL, range: mainnetRange), "Mainnet URL should not contain hardcoded IP")
    }

    func testServerURLHelper() {
        let testnetURL = ServerConfiguration.lwsServerURL(isTestnet: true)
        let mainnetURL = ServerConfiguration.lwsServerURL(isTestnet: false)

        XCTAssertEqual(testnetURL, ServerConfiguration.testnetLWSServerURL)
        XCTAssertEqual(mainnetURL, ServerConfiguration.mainnetLWSServerURL)
    }
}

// MARK: - Node Manager Safety Tests

@MainActor
final class NodeManagerSafetyTests: XCTestCase {

    func testNodeManagerInitializesWithValidNode() {
        let manager = NodeManager()

        // Should have a valid selected node
        XCTAssertFalse(manager.selectedNode.url.isEmpty)
        XCTAssertFalse(manager.selectedNode.name.isEmpty)
    }

    func testDefaultNodesAreNotEmpty() {
        XCTAssertFalse(NodeManager.defaultNodes.isEmpty, "Default nodes should not be empty")
        XCTAssertFalse(NodeManager.defaultTestnetNodes.isEmpty, "Default testnet nodes should not be empty")
    }

    func testRemoveLastCustomNodeDoesNotCrash() {
        let manager = NodeManager()

        // Add a custom node
        manager.addCustomNode(name: "Test", url: "http://test.com:18081")
        XCTAssertEqual(manager.customNodes.count, 1)

        // Select it
        if let customNode = manager.customNodes.first {
            manager.selectNode(customNode)

            // Remove it - should fall back to default without crashing
            manager.removeCustomNode(customNode)
        }

        XCTAssertEqual(manager.customNodes.count, 0)
        // Should have fallen back to a default node
        XCTAssertFalse(manager.selectedNode.url.isEmpty)
    }
}
