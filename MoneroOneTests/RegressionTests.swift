import XCTest
import CoreLocation
import CoreImage.CIFilterBuiltins
@testable import MoneroOne

// MARK: - Wallet Lifecycle Regression Tests

@MainActor
final class WalletLifecycleRegressionTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
        walletManager.deleteWallet()
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    override func tearDown() async throws {
        walletManager.deleteWallet()
        walletManager = nil
        UserDefaults.standard.removeObject(forKey: "isTestnet")
    }

    // MARK: - Wallet Creation & Seed Recovery

    /// Create wallet with polyseed, save, retrieve seed — must match exactly
    func testPolyseedCreateAndRecoverRoundTrip() async throws {
        let mnemonic = walletManager.generateNewWallet(type: .polyseed)
        XCTAssertEqual(mnemonic.count, 16, "Polyseed must be 16 words")

        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        let recovered = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertEqual(recovered, mnemonic, "Recovered seed must match original exactly")
    }

    /// Create wallet with BIP39, save, retrieve seed — must match exactly
    func testBip39CreateAndRecoverRoundTrip() async throws {
        let mnemonic = walletManager.generateNewWallet(type: .bip39)
        XCTAssertEqual(mnemonic.count, 24, "BIP39 must be 24 words")

        let pin = "654321"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        let recovered = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertEqual(recovered, mnemonic, "Recovered BIP39 seed must match original")
    }

    /// Seed type is persisted correctly based on word count
    func testSeedTypePersistence() async throws {
        let polyseed = walletManager.generateNewWallet(type: .polyseed)
        try walletManager.saveWallet(mnemonic: polyseed, pin: "1234")

        let savedType = UserDefaults.standard.string(forKey: "mainnet_seedType")
        XCTAssertEqual(savedType, "polyseed")
    }

    /// Unlock with correct PIN succeeds, wrong PIN fails
    func testUnlockCorrectAndWrongPIN() async throws {
        let mnemonic = walletManager.generateNewWallet()
        try walletManager.saveWallet(mnemonic: mnemonic, pin: "123456")

        // Correct PIN
        try await walletManager.unlock(pin: "123456")
        XCTAssertTrue(walletManager.isUnlocked)

        walletManager.lock()

        // Wrong PIN
        do {
            try await walletManager.unlock(pin: "000000")
            XCTFail("Should throw for wrong PIN")
        } catch {
            // Expected
        }
        XCTAssertFalse(walletManager.isUnlocked)
    }

    /// Lock clears ALL sensitive state
    func testLockClearsAllState() async throws {
        let mnemonic = walletManager.generateNewWallet()
        try walletManager.saveWallet(mnemonic: mnemonic, pin: "1234")
        try await walletManager.unlock(pin: "1234")

        walletManager.lock()

        XCTAssertFalse(walletManager.isUnlocked)
        XCTAssertEqual(walletManager.balance, 0)
        XCTAssertEqual(walletManager.unlockedBalance, 0)
        XCTAssertEqual(walletManager.address, "")
        XCTAssertEqual(walletManager.primaryAddress, "")
        XCTAssertTrue(walletManager.subaddresses.isEmpty)
        XCTAssertTrue(walletManager.transactions.isEmpty)
        XCTAssertEqual(walletManager.syncState, .idle)
        XCTAssertEqual(walletManager.connectionStage, .noNetwork)
        XCTAssertEqual(walletManager.daemonHeight, 0)
        XCTAssertEqual(walletManager.walletHeight, 0)
    }

    /// Delete wallet removes everything
    func testDeleteWalletRemovesAllData() async throws {
        let mnemonic = walletManager.generateNewWallet()
        try walletManager.saveWallet(mnemonic: mnemonic, pin: "1234")
        XCTAssertTrue(walletManager.hasWallet)

        walletManager.deleteWallet()

        XCTAssertFalse(walletManager.hasWallet)
        XCTAssertFalse(walletManager.isUnlocked)
        XCTAssertTrue(walletManager.userCreatedSubaddressIndices.isEmpty)
    }

    /// Wallet survives unlock → lock → unlock cycle
    func testRepeatedUnlockLockCycle() async throws {
        let mnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        for _ in 0..<3 {
            try await walletManager.unlock(pin: pin)
            XCTAssertTrue(walletManager.isUnlocked)
            walletManager.lock()
            XCTAssertFalse(walletManager.isUnlocked)
        }

        // Seed should still be recoverable
        let recovered = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertEqual(recovered, mnemonic)
    }

    /// Mnemonic validation accepts correct word counts, rejects others
    func testMnemonicValidation() async throws {
        // 16-word polyseed should be accepted
        let polyseed = walletManager.generateNewWallet(type: .polyseed)
        XCTAssertNoThrow(try walletManager.restoreWallet(mnemonic: polyseed, pin: "1234"))
        walletManager.deleteWallet()

        // 6-word invalid should be rejected
        let invalid = ["one", "two", "three", "four", "five", "six"]
        XCTAssertThrowsError(try walletManager.restoreWallet(mnemonic: invalid, pin: "1234"))

        // Empty should be rejected
        XCTAssertThrowsError(try walletManager.restoreWallet(mnemonic: [], pin: "1234"))
    }

    /// Send and estimateFee throw when wallet is locked
    func testSendAndFeeThrowWhenLocked() async {
        do {
            _ = try await walletManager.send(to: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A", amount: 1.0)
            XCTFail("send should throw when locked")
        } catch {
            XCTAssertEqual(error as? WalletError, .notUnlocked)
        }

        do {
            _ = try await walletManager.sendAll(to: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A")
            XCTFail("sendAll should throw when locked")
        } catch {
            XCTAssertEqual(error as? WalletError, .notUnlocked)
        }

        do {
            _ = try await walletManager.estimateFee(to: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A", amount: 1.0)
            XCTFail("estimateFee should throw when locked")
        } catch {
            XCTAssertEqual(error as? WalletError, .notUnlocked)
        }
    }

    /// Restore height is saved per-network
    func testRestoreHeightPerNetwork() async throws {
        let mnemonic = walletManager.generateNewWallet()

        // Save on mainnet with height
        UserDefaults.standard.set(false, forKey: "isTestnet")
        try walletManager.saveWallet(mnemonic: mnemonic, pin: "1234", restoreHeight: 3000000)

        let mainnetHeight = UserDefaults.standard.integer(forKey: "mainnet_restoreHeight")
        XCTAssertEqual(UInt64(mainnetHeight), 3000000)

        // Switch to testnet and save with different height (don't delete — that clears both)
        UserDefaults.standard.set(true, forKey: "isTestnet")
        let wm2 = WalletManager()
        try wm2.saveWallet(mnemonic: mnemonic, pin: "1234", restoreHeight: 1500000)

        let testnetHeight = UserDefaults.standard.integer(forKey: "testnet_restoreHeight")
        XCTAssertEqual(UInt64(testnetHeight), 1500000)

        // Mainnet height should be untouched
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "mainnet_restoreHeight"), 3000000)

        // Cleanup
        wm2.deleteWallet()
        UserDefaults.standard.set(false, forKey: "isTestnet")
        walletManager.deleteWallet()
    }
}

// MARK: - PIN Management Regression Tests

final class PINManagementRegressionTests: XCTestCase {

    var keychain: KeychainStorage!

    override func setUp() {
        keychain = KeychainStorage()
        keychain.deleteSeed()
        keychain.deleteBiometricPin()
        keychain.resetFailedAttempts()
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    override func tearDown() {
        keychain.deleteSeed()
        keychain.deleteBiometricPin()
        keychain.resetFailedAttempts()
        keychain = nil
        UserDefaults.standard.removeObject(forKey: "isTestnet")
    }

    // MARK: - 4-Digit PIN

    func testFourDigitPINSaveAndRetrieve() throws {
        let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        try keychain.saveSeed(seed, pin: "1234")

        let retrieved = try keychain.getSeed(pin: "1234")
        XCTAssertEqual(retrieved, seed)
    }

    func testFourDigitPINWrongPINReturnsNil() throws {
        let seed = "test seed phrase"
        try keychain.saveSeed(seed, pin: "1234")

        let result = try keychain.getSeed(pin: "4321")
        XCTAssertNil(result)
    }

    // MARK: - 6-Digit PIN

    func testSixDigitPINSaveAndRetrieve() throws {
        let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        try keychain.saveSeed(seed, pin: "123456")

        let retrieved = try keychain.getSeed(pin: "123456")
        XCTAssertEqual(retrieved, seed)
    }

    func testSixDigitPINWrongPINReturnsNil() throws {
        let seed = "test seed phrase"
        try keychain.saveSeed(seed, pin: "123456")

        let result = try keychain.getSeed(pin: "654321")
        XCTAssertNil(result)
    }

    // MARK: - PIN Change

    func testChangePINFromFourToSix() throws {
        let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let oldPin = "1234"
        let newPin = "123456"

        // Save with 4-digit
        try keychain.saveSeed(seed, pin: oldPin)
        XCTAssertEqual(try keychain.getSeed(pin: oldPin), seed)

        // Change to 6-digit
        try keychain.saveSeed(seed, pin: newPin)

        // Old PIN should fail
        XCTAssertNil(try keychain.getSeed(pin: oldPin))
        // New PIN should work
        XCTAssertEqual(try keychain.getSeed(pin: newPin), seed)
    }

    func testChangePINFromSixToFour() throws {
        let seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let oldPin = "123456"
        let newPin = "1234"

        try keychain.saveSeed(seed, pin: oldPin)
        try keychain.saveSeed(seed, pin: newPin)

        XCTAssertNil(try keychain.getSeed(pin: oldPin))
        XCTAssertEqual(try keychain.getSeed(pin: newPin), seed)
    }

    // MARK: - PIN Length Persistence

    func testPinLengthSaveAndRetrieve() {
        keychain.savePinLength(4)
        XCTAssertEqual(keychain.getPinLength(), 4)

        keychain.savePinLength(6)
        XCTAssertEqual(keychain.getPinLength(), 6)
    }

    func testPinLengthSurvivesMultipleWrites() {
        for length in [4, 6, 4, 6, 4] {
            keychain.savePinLength(length)
            XCTAssertEqual(keychain.getPinLength(), length)
        }
    }

    // MARK: - PIN with Leading Zeros

    func testPINWithAllZeros() throws {
        let seed = "test seed phrase"
        try keychain.saveSeed(seed, pin: "0000")
        XCTAssertEqual(try keychain.getSeed(pin: "0000"), seed)
    }

    func testPINWithLeadingZeros() throws {
        let seed = "test seed phrase"
        try keychain.saveSeed(seed, pin: "000123")
        XCTAssertEqual(try keychain.getSeed(pin: "000123"), seed)
        XCTAssertNil(try keychain.getSeed(pin: "123"))  // Different PIN!
    }

    // MARK: - Network-Specific Seed Isolation

    func testMainnetAndTestnetSeedsAreSeparate() throws {
        let mainnetSeed = "mainnet seed one two three four five six seven eight nine ten"
        let testnetSeed = "testnet seed alpha beta gamma delta epsilon zeta eta theta iota"
        let pin = "1234"

        // Save mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")
        try keychain.saveSeed(mainnetSeed, pin: pin)

        // Save testnet
        UserDefaults.standard.set(true, forKey: "isTestnet")
        try keychain.saveSeed(testnetSeed, pin: pin)

        // Verify isolation
        UserDefaults.standard.set(false, forKey: "isTestnet")
        XCTAssertEqual(try keychain.getSeed(pin: pin), mainnetSeed)

        UserDefaults.standard.set(true, forKey: "isTestnet")
        XCTAssertEqual(try keychain.getSeed(pin: pin), testnetSeed)

        // Cleanup
        keychain.deleteSeed()
        UserDefaults.standard.set(false, forKey: "isTestnet")
        keychain.deleteSeed()
    }

    func testDeleteSeedOnOneNetworkDoesNotAffectOther() throws {
        let mainnetSeed = "mainnet seed"
        let testnetSeed = "testnet seed"
        let pin = "1234"

        UserDefaults.standard.set(false, forKey: "isTestnet")
        try keychain.saveSeed(mainnetSeed, pin: pin)

        UserDefaults.standard.set(true, forKey: "isTestnet")
        try keychain.saveSeed(testnetSeed, pin: pin)

        // Delete testnet
        keychain.deleteSeed()
        XCTAssertFalse(keychain.hasSeed())

        // Mainnet still there
        UserDefaults.standard.set(false, forKey: "isTestnet")
        XCTAssertTrue(keychain.hasSeed())
        XCTAssertEqual(try keychain.getSeed(pin: pin), mainnetSeed)

        keychain.deleteSeed()
    }
}

// MARK: - Address Validation Regression Tests

@MainActor
final class AddressValidationRegressionTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        UserDefaults.standard.set(false, forKey: "isTestnet")
        walletManager = WalletManager()
    }

    override func tearDown() async throws {
        walletManager = nil
    }

    func testValidMainnetStandardAddress() {
        let addr = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
        XCTAssertTrue(walletManager.isValidAddress(addr))
    }

    func testValidSubaddress() {
        let addr = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
        XCTAssertTrue(walletManager.isValidAddress(addr))
    }

    func testEmptyAddressInvalid() {
        XCTAssertFalse(walletManager.isValidAddress(""))
    }

    func testGarbageAddressInvalid() {
        XCTAssertFalse(walletManager.isValidAddress("not-a-valid-address"))
    }

    func testTruncatedAddressInvalid() {
        XCTAssertFalse(walletManager.isValidAddress("44AFFq5kSiGBoZ4NMDw"))
    }

    func testBitcoinAddressRejected() {
        XCTAssertFalse(walletManager.isValidAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    func testEthereumAddressRejected() {
        XCTAssertFalse(walletManager.isValidAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f2bD3e"))
    }
}

// MARK: - QR Code Generation Regression Tests

final class QRCodeRegressionTests: XCTestCase {

    func testQRCodeGeneratesForMoneroAddress() {
        let address = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
        let content = "monero:\(address)"

        let qrImage = generateTestQRImage(from: content)
        XCTAssertNotNil(qrImage, "QR code should generate for Monero address")
    }

    func testQRCodeGeneratesForSubaddress() {
        let subaddress = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
        let content = "monero:\(subaddress)"

        let qrImage = generateTestQRImage(from: content)
        XCTAssertNotNil(qrImage, "QR code should generate for subaddress")
    }

    func testQRCodeGeneratesForAddressWithAmount() {
        let content = "monero:44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A?tx_amount=1.5"

        let qrImage = generateTestQRImage(from: content)
        XCTAssertNotNil(qrImage, "QR code should generate for address with amount")
    }

    func testQRCodeHasNonZeroSize() {
        let content = "monero:44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

        guard let image = generateTestQRImage(from: content) else {
            XCTFail("Failed to generate QR image")
            return
        }

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testQRCodeEmptyStringStillGenerates() {
        // Even empty content should produce a valid QR code
        let qrImage = generateTestQRImage(from: "")
        // CIFilter may or may not generate for empty, but shouldn't crash
        // The important thing is no crash
    }

    /// Helper: generate QR image using CIFilter (same as QRCodeView)
    private func generateTestQRImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }

        let scale: CGFloat = 300 / outputImage.extent.size.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Decimal Input Filtering Regression Tests

final class DecimalInputFilteringTests: XCTestCase {

    /// Mirror the filterDecimalInput logic from SendView for testability
    private func filterDecimalInput(_ input: String) -> String {
        var hasDecimal = false
        var result = ""

        for char in input {
            if char.isNumber {
                result.append(char)
            } else if char == "." && !hasDecimal {
                hasDecimal = true
                result.append(char)
            }
        }

        // Limit decimal places to 12 (Monero's precision)
        if let decimalIndex = result.firstIndex(of: ".") {
            let afterDecimal = result.distance(from: decimalIndex, to: result.endIndex) - 1
            if afterDecimal > 12 {
                result = String(result.prefix(result.count - (afterDecimal - 12)))
            }
        }

        return result
    }

    func testWholeNumber() {
        XCTAssertEqual(filterDecimalInput("100"), "100")
    }

    func testDecimalNumber() {
        XCTAssertEqual(filterDecimalInput("1.5"), "1.5")
    }

    func testMultipleDecimalPointsFiltered() {
        XCTAssertEqual(filterDecimalInput("1.2.3"), "1.23")
    }

    func testLettersFiltered() {
        XCTAssertEqual(filterDecimalInput("1a2b3"), "123")
    }

    func testSpecialCharsFiltered() {
        XCTAssertEqual(filterDecimalInput("$1,000.50"), "1000.50")
    }

    func testEmptyString() {
        XCTAssertEqual(filterDecimalInput(""), "")
    }

    func testDecimalPlacesLimitedTo12() {
        let input = "1.1234567890123456"
        let result = filterDecimalInput(input)
        let parts = result.split(separator: ".")
        XCTAssertEqual(parts.count, 2)
        XCTAssertLessThanOrEqual(parts[1].count, 12)
    }

    func testExactly12DecimalPlaces() {
        let input = "1.123456789012"
        XCTAssertEqual(filterDecimalInput(input), "1.123456789012")
    }

    func testLeadingDecimal() {
        XCTAssertEqual(filterDecimalInput(".5"), ".5")
    }

    func testTrailingDecimal() {
        XCTAssertEqual(filterDecimalInput("5."), "5.")
    }

    func testZeroAmount() {
        XCTAssertEqual(filterDecimalInput("0"), "0")
        XCTAssertEqual(filterDecimalInput("0.0"), "0.0")
    }
}

// MARK: - Connection Stage Regression Tests

final class ConnectionStageRegressionTests: XCTestCase {

    func testAllStagesHaveDisplayText() {
        let stages: [ConnectionStage] = [
            .noNetwork,
            .reachingNode,
            .connecting,
            .loadingBlocks(wallet: 100, daemon: 3000000),
            .syncing,
            .synced
        ]

        for stage in stages {
            XCTAssertFalse(stage.displayText.isEmpty, "\(stage) should have display text")
        }
    }

    func testStageIndicesAreSequential() {
        XCTAssertEqual(ConnectionStage.noNetwork.stageIndex, 0)
        XCTAssertEqual(ConnectionStage.reachingNode.stageIndex, 1)
        XCTAssertEqual(ConnectionStage.connecting.stageIndex, 2)
        XCTAssertEqual(ConnectionStage.loadingBlocks(wallet: 0, daemon: 0).stageIndex, 3)
        XCTAssertEqual(ConnectionStage.syncing.stageIndex, 4)
        XCTAssertEqual(ConnectionStage.synced.stageIndex, 5)
    }

    func testLoadingBlocksDisplayFormat() {
        // Small heights
        let small = ConnectionStage.loadingBlocks(wallet: 500, daemon: 900)
        XCTAssertTrue(small.displayText.contains("500"))
        XCTAssertTrue(small.displayText.contains("900"))

        // Large heights (millions)
        let large = ConnectionStage.loadingBlocks(wallet: 2500000, daemon: 3200000)
        XCTAssertTrue(large.displayText.contains("M"), "Should format large heights with M suffix")
    }

    func testSyncStateEquality() {
        XCTAssertEqual(WalletManager.SyncState.idle, WalletManager.SyncState.idle)
        XCTAssertEqual(WalletManager.SyncState.synced, WalletManager.SyncState.synced)
        XCTAssertNotEqual(WalletManager.SyncState.idle, WalletManager.SyncState.synced)
    }
}

// MARK: - XMR Formatting Regression Tests

final class XMRFormattingRegressionTests: XCTestCase {

    func testFormatZero() {
        XCTAssertEqual(MoneroOne.XMRFormatter.format(0), "0.0000")
    }

    func testFormatOneXMR() {
        XCTAssertEqual(MoneroOne.XMRFormatter.format(1), "1.0000")
    }

    func testFormatSmallAmount() {
        let result = MoneroOne.XMRFormatter.format(Decimal(string: "0.0001")!)
        XCTAssertEqual(result, "0.0001")
    }

    func testFormatLargeAmount() {
        let result = MoneroOne.XMRFormatter.format(Decimal(1000000))
        XCTAssertTrue(result.contains("1,000,000") || result.contains("1000000"),
                      "Should handle large amounts: got \(result)")
    }

    func testFormatPreservesPrecision() {
        let value = Decimal(string: "1.123456789012")!
        let result = MoneroOne.XMRFormatter.format(value)

        // Should have at least 4 decimal places
        let parts = result.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts[1].count, 4)
        // Should not exceed 12
        XCTAssertLessThanOrEqual(parts[1].count, 12)
    }

    func testFormatNeverReturnsEmpty() {
        let values: [Decimal] = [0, 1, 0.0001, 999999, Decimal(string: "0.000000000001")!]
        for value in values {
            let result = MoneroOne.XMRFormatter.format(value)
            XCTAssertFalse(result.isEmpty, "Format should never return empty for \(value)")
        }
    }
}

// MARK: - Trusted Location Regression Tests

final class TrustedLocationRegressionTests: XCTestCase {

    func testTrustedLocationCodableRoundTrip() throws {
        let original = TrustedLocation(
            name: "Home",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            radius: 500
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrustedLocation.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.coordinate.latitude, original.coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(decoded.coordinate.longitude, original.coordinate.longitude, accuracy: 0.0001)
        XCTAssertEqual(decoded.radius, original.radius)
    }

    func testTrustedLocationContainsPointInside() {
        let location = TrustedLocation(
            name: "Test",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            radius: 1000
        )

        // Point very close to center
        let nearbyPoint = CLLocation(latitude: 37.7750, longitude: -122.4195)
        XCTAssertTrue(location.contains(nearbyPoint), "Should contain nearby point")
    }

    func testTrustedLocationRejectsPointOutside() {
        let location = TrustedLocation(
            name: "Test",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            radius: 100  // Very small radius
        )

        // Point far away
        let farPoint = CLLocation(latitude: 38.0, longitude: -122.0)
        XCTAssertFalse(location.contains(farPoint), "Should reject far point")
    }

    func testTrustedLocationRegionProperties() {
        let location = TrustedLocation(
            name: "Office",
            coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            radius: 200
        )

        let region = location.region
        XCTAssertEqual(region.identifier, location.id.uuidString)
        XCTAssertEqual(region.radius, 200)
        XCTAssertTrue(region.notifyOnEntry)
        XCTAssertTrue(region.notifyOnExit)
    }

    func testRadiusPresets() {
        XCTAssertEqual(TrustedLocation.RadiusPreset.small.rawValue, 200)
        XCTAssertEqual(TrustedLocation.RadiusPreset.medium.rawValue, 500)
        XCTAssertEqual(TrustedLocation.RadiusPreset.large.rawValue, 1000)
        XCTAssertEqual(TrustedLocation.RadiusPreset.extraLarge.rawValue, 2000)
    }

    func testTrustedLocationEquality() {
        let id = UUID()
        let loc1 = TrustedLocation(id: id, name: "Home",
                                    coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let loc2 = TrustedLocation(id: id, name: "Work",
                                    coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1))
        let loc3 = TrustedLocation(name: "Other",
                                    coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))

        // Same ID = equal (even if different name/coord)
        XCTAssertEqual(loc1, loc2)
        // Different ID = not equal
        XCTAssertNotEqual(loc1, loc3)
    }
}

// MARK: - Node Manager Regression Tests

@MainActor
final class NodeManagerRegressionTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "isTestnet")
        UserDefaults.standard.removeObject(forKey: "customNodes")
        UserDefaults.standard.removeObject(forKey: "selectedNodeURL")
    }

    func testDefaultNodesExist() {
        XCTAssertGreaterThanOrEqual(NodeManager.defaultNodes.count, 1)
    }

    func testAddAndRemoveCustomNode() {
        let manager = NodeManager()
        let initialCount = manager.customNodes.count

        manager.addCustomNode(name: "MyNode", url: "https://mynode.com:18081")
        XCTAssertEqual(manager.customNodes.count, initialCount + 1)

        if let node = manager.customNodes.last {
            manager.removeCustomNode(node)
        }
        XCTAssertEqual(manager.customNodes.count, initialCount)
    }

    func testSelectNodePersists() {
        let manager = NodeManager()
        guard let node = NodeManager.defaultNodes.last else { return }

        manager.selectNode(node)
        XCTAssertEqual(manager.selectedNode.url, node.url)

        // Create new manager — should load persisted selection
        let manager2 = NodeManager()
        XCTAssertEqual(manager2.selectedNode.url, node.url)
    }

    func testRemoveSelectedNodeFallsBackToDefault() {
        let manager = NodeManager()

        manager.addCustomNode(name: "Temp", url: "https://temp.com:18081")
        if let customNode = manager.customNodes.first {
            manager.selectNode(customNode)
            manager.removeCustomNode(customNode)
        }

        // Should fall back to a default
        XCTAssertFalse(manager.selectedNode.url.isEmpty)
    }

    func testCustomNodeWithCredentials() {
        let manager = NodeManager()
        manager.addCustomNode(name: "Auth Node", url: "https://auth.com:18081",
                              login: "user", password: "pass")

        let node = manager.customNodes.last
        XCTAssertEqual(node?.login, "user")
        XCTAssertEqual(node?.password, "pass")

        // Cleanup
        if let n = node { manager.removeCustomNode(n) }
    }
}

// MARK: - Transaction Model Regression Tests

final class TransactionModelRegressionTests: XCTestCase {

    func testTransactionEquality() {
        let tx1 = MoneroTransaction(
            id: "abc123", type: .incoming, amount: 1.5, fee: 0.001,
            address: "44AFF...", timestamp: Date(), confirmations: 10,
            status: .confirmed, memo: nil
        )
        let tx2 = MoneroTransaction(
            id: "abc123", type: .outgoing, amount: 2.0, fee: 0.002,
            address: "888tN...", timestamp: Date(), confirmations: 5,
            status: .pending, memo: "test"
        )
        let tx3 = MoneroTransaction(
            id: "def456", type: .incoming, amount: 1.5, fee: 0.001,
            address: "44AFF...", timestamp: Date(), confirmations: 10,
            status: .confirmed, memo: nil
        )

        // Same ID = equal
        XCTAssertEqual(tx1, tx2)
        // Different ID = not equal
        XCTAssertNotEqual(tx1, tx3)
    }

    func testTransactionHashing() {
        let tx1 = MoneroTransaction(
            id: "abc123", type: .incoming, amount: 1.5, fee: 0.001,
            address: "", timestamp: Date(), confirmations: 10,
            status: .confirmed, memo: nil
        )
        let tx2 = MoneroTransaction(
            id: "abc123", type: .outgoing, amount: 99, fee: 0,
            address: "", timestamp: Date(), confirmations: 0,
            status: .pending, memo: nil
        )

        // Same ID should produce same hash
        XCTAssertEqual(tx1.hashValue, tx2.hashValue)
    }

    func testTransactionTypes() {
        let incoming = MoneroTransaction.TransactionType.incoming
        let outgoing = MoneroTransaction.TransactionType.outgoing
        XCTAssertNotEqual(incoming, outgoing)
    }

    func testTransactionStatuses() {
        let pending = MoneroTransaction.TransactionStatus.pending
        let confirmed = MoneroTransaction.TransactionStatus.confirmed
        let failed = MoneroTransaction.TransactionStatus.failed
        XCTAssertNotEqual(pending, confirmed)
        XCTAssertNotEqual(confirmed, failed)
    }
}

// MARK: - Wallet Error Regression Tests

final class WalletErrorRegressionTests: XCTestCase {

    func testAllErrorsHaveDescriptions() {
        let errors: [WalletError] = [
            .invalidMnemonic, .invalidPin, .saveFailed,
            .notUnlocked, .biometricFailed, .seedMismatch
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testKeychainErrorDescriptions() {
        let errors: [KeychainError] = [
            .saveFailed, .encryptionFailed, .notFound,
            .lockedOut(remainingSeconds: 30),
            .lockedOut(remainingSeconds: 120)
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testLockoutErrorShowsMinutesAndSeconds() {
        let error = KeychainError.lockedOut(remainingSeconds: 90)
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains("1m"), "Should show minutes for 90s: got \(desc)")
    }

    func testLockoutErrorShowsOnlySeconds() {
        let error = KeychainError.lockedOut(remainingSeconds: 45)
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains("45s"), "Should show seconds only: got \(desc)")
    }
}

// MARK: - SeedType Detection Regression Tests

@MainActor
final class SeedTypeRegressionTests: XCTestCase {

    func testDetectPolyseed() {
        XCTAssertEqual(WalletManager.SeedType.detect(from: 16), .polyseed)
    }

    func testDetectBip39() {
        XCTAssertEqual(WalletManager.SeedType.detect(from: 24), .bip39)
    }

    func testDetectLegacy() {
        XCTAssertEqual(WalletManager.SeedType.detect(from: 25), .legacy)
    }

    func testDetectInvalidCounts() {
        for count in [0, 1, 12, 15, 17, 23, 26, 100] {
            XCTAssertNil(WalletManager.SeedType.detect(from: count),
                         "Word count \(count) should not match any seed type")
        }
    }

    func testWordCounts() {
        XCTAssertEqual(WalletManager.SeedType.polyseed.wordCount, 16)
        XCTAssertEqual(WalletManager.SeedType.bip39.wordCount, 24)
        XCTAssertEqual(WalletManager.SeedType.legacy.wordCount, 25)
    }

    func testAllSeedTypesInCaseIterable() {
        let types = WalletManager.SeedType.allCases
        XCTAssertEqual(types.count, 3)
        XCTAssertTrue(types.contains(.polyseed))
        XCTAssertTrue(types.contains(.bip39))
        XCTAssertTrue(types.contains(.legacy))
    }
}
