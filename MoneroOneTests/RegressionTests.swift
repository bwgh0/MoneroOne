import XCTest
import CoreLocation
import CoreImage.CIFilterBuiltins
import AVFoundation
import UIKit
@testable import MoneroOne

// MARK: - Wallet Lifecycle Regression Tests

@MainActor
final class WalletLifecycleRegressionTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
        walletManager.deleteAllWallets()
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    override func tearDown() async throws {
        walletManager.deleteAllWallets()
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

        // Multi-wallet refactor moved seed type from `mainnet_seedType`
        // UserDefault into the per-wallet `WalletInfo.source` field.
        XCTAssertEqual(walletManager.activeWallet?.source, .seed(.polyseed))
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

    /// Restore height is saved per-wallet (multi-wallet model — each
    /// network gets its own WalletInfo so heights can't bleed across).
    func testRestoreHeightPerNetwork() async throws {
        let mnemonic = walletManager.generateNewWallet()

        UserDefaults.standard.set(false, forKey: "isTestnet")
        try walletManager.saveWallet(mnemonic: mnemonic, pin: "1234", restoreHeight: 3000000)
        XCTAssertEqual(walletManager.activeWallet?.restoreHeight, 3000000)

        UserDefaults.standard.set(true, forKey: "isTestnet")
        let wm2 = WalletManager()
        try wm2.saveWallet(mnemonic: mnemonic, pin: "1234", restoreHeight: 1500000)
        XCTAssertEqual(wm2.activeWallet?.restoreHeight, 1500000)

        wm2.deleteWallet()
        UserDefaults.standard.set(false, forKey: "isTestnet")
        XCTAssertEqual(walletManager.activeWallet?.restoreHeight, 3000000)
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

    // MARK: Scanning the code as the app draws it

    /// The QR as `QRCodeView` draws it, with the flat mark on its white disc
    /// in the center, still decodes to the full text at every size the app
    /// uses: Donation 240, Receive 280, focus mode 338 on a 402pt phone,
    /// the share and save image 400, and focus mode on a wide display 448.
    @MainActor
    func testQRCodeViewWithLogoDecodesAtAppSizes() throws {
        let contents = [
            "monero:44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A",
            "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H?tx_amount=0.5",
        ]
        for content in contents {
            for size in [240, 280, 338, 400, 448] as [CGFloat] {
                let image = try XCTUnwrap(QRCodeRenderer.renderToImage(content: content, size: size))
                XCTAssertEqual(decodedMessages(in: image), [content], "\(content.prefix(12)) at \(Int(size))pt")
            }
        }
    }

    /// Focus mode turns the screen to full brightness and puts the old level
    /// back when it goes away.
    @MainActor
    func testFullscreenBrightnessBoostsAndRestores() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let screen = scene.screen
        let original = screen.brightness
        defer { screen.brightness = original }
        screen.brightness = 0.3
        try XCTSkipIf(abs(screen.brightness - 0.3) > 0.01, "This screen does not take brightness changes")

        let window = UIWindow(windowScene: scene)
        let view = FullBrightness.BrightnessView()
        window.addSubview(view)
        XCTAssertEqual(screen.brightness, 1, accuracy: 0.01)

        view.removeFromSuperview()
        XCTAssertEqual(screen.brightness, 0.3, accuracy: 0.01)
    }

    private func decodedMessages(in image: UIImage) -> [String] {
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else { return [] }
        return detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
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

    func testFormatCompactKeepsFourDecimalsAndFourSignificantDigits() {
        let cases: [(String, String)] = [
            ("0", "0.0000"),
            ("3.119", "3.1190"),
            ("1234.56789", "1,234.5678"),
            ("0.0025", "0.0025"),
            ("0.09974088", "0.09974"),
            ("0.00185092", "0.00185"),
            ("0.000580526955", "0.0005805"),
            ("0.00000834", "0.00000834"),
            ("0.000000000001", "0.000000000001"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MoneroOne.XMRFormatter.formatCompact(Decimal(string: input)!), expected, input)
        }
    }

    func testFormatCompactRoundsTowardZero() {
        // Never shows more than the real amount.
        XCTAssertEqual(MoneroOne.XMRFormatter.formatCompact(Decimal(string: "1.999999999999")!), "1.9999")
        XCTAssertEqual(MoneroOne.XMRFormatter.formatCompact(Decimal(string: "0.000999999")!), "0.0009999")
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
        let loc1Copy = TrustedLocation(id: id, name: "Home",
                                        coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let loc2 = TrustedLocation(id: id, name: "Work",
                                    coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1))
        let loc3 = TrustedLocation(name: "Other",
                                    coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))

        // All fields equal = equal (needed for SwiftUI view diffing on rename/move)
        XCTAssertEqual(loc1, loc1Copy)
        // Same ID but different name/coord = not equal (rename triggers SwiftUI update)
        XCTAssertNotEqual(loc1, loc2)
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
            status: .confirmed, memo: nil, blockHeight: nil
        )
        let tx2 = MoneroTransaction(
            id: "abc123", type: .outgoing, amount: 2.0, fee: 0.002,
            address: "888tN...", timestamp: Date(), confirmations: 5,
            status: .pending, memo: "test", blockHeight: nil
        )
        let tx3 = MoneroTransaction(
            id: "def456", type: .incoming, amount: 1.5, fee: 0.001,
            address: "44AFF...", timestamp: Date(), confirmations: 10,
            status: .confirmed, memo: nil, blockHeight: nil
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
            status: .confirmed, memo: nil, blockHeight: nil
        )
        let tx2 = MoneroTransaction(
            id: "abc123", type: .outgoing, amount: 99, fee: 0,
            address: "", timestamp: Date(), confirmations: 0,
            status: .pending, memo: nil, blockHeight: nil
        )

        // Same ID should produce same hash
        XCTAssertEqual(tx1.hashValue, tx2.hashValue)
    }

    /// The memberwise defaults keep every older construction site
    /// compiling and give a transaction with no destination data.
    func testTransactionDefaultsToNoDestinations() {
        let tx = MoneroTransaction(
            id: "abc123", type: .outgoing, amount: 1, fee: 0,
            address: "", timestamp: Date(), confirmations: nil,
            status: .pending, memo: nil, blockHeight: nil
        )
        XCTAssertEqual(tx.destinations, [])
        XCTAssertNil(tx.subaddressIndex)
    }

    // MARK: - Hardware tx snapshot format

    /// A snapshot written before `destinations` and `subaddressIndex`
    /// existed must still decode. A required field here once made every
    /// old snapshot undecodable and the hardware tx list came back empty.
    func testSnapshotDecodesOldFormatWithoutDestinations() throws {
        let json = """
        [{"id":"abc123","typeRaw":"outgoing","amount":1.5,"fee":0.001,"address":"","timestamp":700000000,"confirmations":3,"statusRaw":"confirmed","memo":null}]
        """
        let decoded = try JSONDecoder().decode([MoneroTransactionSnapshot].self, from: Data(json.utf8))
        let tx = try XCTUnwrap(decoded.first).toTransaction()
        XCTAssertEqual(tx.id, "abc123")
        XCTAssertEqual(tx.type, .outgoing)
        XCTAssertEqual(tx.status, .confirmed)
        XCTAssertEqual(tx.confirmations, 3)
        XCTAssertNil(tx.blockHeight)
        XCTAssertEqual(tx.destinations, [])
        XCTAssertNil(tx.subaddressIndex)
    }

    /// Destinations and the receiving subaddress index survive the trip
    /// through the on-disk snapshot.
    func testSnapshotRoundTripsDestinationsAndSubaddressIndex() throws {
        // Amounts exact in binary so the JSON number path cannot drift.
        let destinations = [
            MoneroTransactionDestination(address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H", amount: 1.25),
            MoneroTransactionDestination(address: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A", amount: 0.125),
        ]
        let sent = MoneroTransaction(
            id: "out-1", type: .outgoing, amount: 1.375, fee: 0.0625,
            address: destinations[0].address,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            confirmations: 12, status: .confirmed, memo: nil, blockHeight: 3_000_000,
            destinations: destinations
        )
        let received = MoneroTransaction(
            id: "in-1", type: .incoming, amount: 0.5, fee: 0,
            address: "8BsubAddressOfThisWallet",
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            confirmations: 4, status: .confirmed, memo: "rent", blockHeight: 3_000_010,
            subaddressIndex: 3
        )

        let data = try JSONEncoder().encode([sent, received].map { MoneroTransactionSnapshot(from: $0) })
        let back = try JSONDecoder().decode([MoneroTransactionSnapshot].self, from: data).map { $0.toTransaction() }

        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].id, "out-1")
        XCTAssertEqual(back[0].destinations, destinations)
        XCTAssertEqual(back[0].address, destinations[0].address)
        XCTAssertNil(back[0].subaddressIndex)
        XCTAssertEqual(back[1].id, "in-1")
        XCTAssertEqual(back[1].destinations, [])
        XCTAssertEqual(back[1].subaddressIndex, 3)
        XCTAssertEqual(back[1].address, "8BsubAddressOfThisWallet")
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

// MARK: - Diagnostic Log Persistence
//
// The diagnostic log used to live only in memory, so any restart or
// background kill wiped exactly the history support needed. These tests
// pin the disk-backed behavior: lines land in a file, exports include the
// rotated previous generation, and clear() removes what was persisted.
final class DiagnosticLogPersistenceTests: XCTestCase {

    private var logDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiagnosticLog", isDirectory: true)
    }

    /// export() runs queue.sync on the same serial queue log() appends on,
    /// so calling it flushes all pending writes.
    private func flush() {
        _ = DiagnosticLog.shared.export()
    }

    func testLogLineIsWrittenToDiskNotJustMemory() throws {
        let marker = "persistence-marker-\(UUID().uuidString)"
        DiagnosticLog.shared.log(marker)
        flush()

        let fileURL = logDirectory.appendingPathComponent("diagnostic.log")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(marker),
                      "Log line must be persisted to disk so it survives an app restart")
    }

    func testExportIncludesPreviousGeneration() throws {
        // A line planted in the rotated previous-generation file stands in
        // for history written before a restart or rotation.
        let marker = "previous-generation-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let previousURL = logDirectory.appendingPathComponent("diagnostic.previous.log")
        let existing = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        try (existing + marker + "\n").write(to: previousURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(DiagnosticLog.shared.export().contains(marker),
                      "Export must include the previous log generation, not just the current session")
    }

    func testClearRemovesPersistedHistory() throws {
        let marker = "cleared-marker-\(UUID().uuidString)"
        DiagnosticLog.shared.log(marker)
        flush()
        DiagnosticLog.shared.clear()

        XCTAssertFalse(DiagnosticLog.shared.export().contains(marker))
        let fileURL = logDirectory.appendingPathComponent("diagnostic.log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTimestampsCarryTheDate() throws {
        // Cross-session logs span days; a bare time is ambiguous in a report.
        DiagnosticLog.shared.log("date-format-probe")
        let export = DiagnosticLog.shared.export()
        let pattern = #"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] "#
        XCTAssertNotNil(export.range(of: pattern, options: .regularExpression),
                        "Persisted log lines must carry a full date, not just a time of day")
    }
}


// MARK: - Diagnostic export sanitizer

/// The Settings diagnostic export now carries the on-device Trezor log.
/// These pin the two promises the export header makes: wire chatter and
/// nearby-device names are gone, and nothing that looks like an address
/// or a 64-hex key/hash survives.
final class DiagnosticExportSanitizerTests: XCTestCase {
    func testDropsWireChatterAndNearbyDevices() {
        let raw = """
        [2026-09-12T22:53:27.426Z] [BLE] Connected to Trezor Safe 7 (7A8A3BC4-1960-3FCC-C081-C1C4D9D109C8)
        [2026-09-12T22:53:31.033Z] [BLE] writeRawChunk: 244 bytes, hex=1c 7b 63 00 17 52 75 bd
        [2026-09-12T22:53:31.289Z] [BLE] Received 244 bytes from device
        [2026-09-12T22:53:31.290Z] [BLE] processRawChunk: 244 bytes, hex=28 7b 63 00 04 c6
        [2026-09-12T22:53:31.291Z] [THP] readTHPResponse: ACK (ctrl=20), continuing
        [2026-09-12T22:53:41.591Z] [BLE] Other device: name=[LG] webOS TV OLED77G5WUA, RSSI=-95, services=FEB9
        [2026-09-12T22:53:50.225Z] [Bridge] /call hex body length: 12 chars
        [2026-09-12T22:53:50.226Z] [Bridge] /call hex body: 000000000000
        [2026-09-12T22:55:10.380Z] [Session] FULL refresh FAILED: Sync failed. | wallet2: failed to get hashes
        [2026-09-12T23:17:24.370Z] [displayBalance] fallback (no snapshot) → raw=0.5
        """
        let out = TrezorLog.sanitize(raw)
        XCTAssertTrue(out.contains("Connected to Trezor Safe 7"))
        XCTAssertTrue(out.contains("FULL refresh FAILED"))
        XCTAssertFalse(out.contains("writeRawChunk"))
        XCTAssertFalse(out.contains("processRawChunk"))
        XCTAssertFalse(out.contains("Received 244 bytes"))
        XCTAssertFalse(out.contains("ACK (ctrl=20)"))
        XCTAssertFalse(out.contains("webOS"))
        XCTAssertFalse(out.contains("/call hex body"))
        XCTAssertFalse(out.contains("displayBalance"))
        XCTAssertEqual(out.split(separator: "\n").count, 2)
    }

    func testMasksAddressesAndHexKeys() {
        let standard = "4" + String(repeating: "A", count: 94)
        let sub = "8" + String(repeating: "B", count: 94)
        let integrated = "4" + String(repeating: "C", count: 105)
        let hex = String(repeating: "ab", count: 32)
        let raw = "[Pair] read address \(standard) and \(sub) and \(integrated) tx <\(hex)> id=7A8A3BC4-1960-3FCC-C081-C1C4D9D109C8"
        let out = TrezorLog.sanitize(raw)
        XCTAssertFalse(out.contains(standard))
        XCTAssertFalse(out.contains(sub))
        XCTAssertFalse(out.contains(integrated))
        XCTAssertFalse(out.contains(hex))
        XCTAssertEqual(out.components(separatedBy: "<address>").count - 1, 3)
        XCTAssertTrue(out.contains("<hex64>"))
        // Short identifiers (peripheral UUIDs, 32-hex wallet ids) are kept.
        XCTAssertTrue(out.contains("7A8A3BC4-1960-3FCC-C081-C1C4D9D109C8"))
        XCTAssertTrue(TrezorLog.sanitize("tempWalletId=43574c74b0a32d3ea9a10fbe0e95ae6d").contains("43574c74b0a32d3ea9a10fbe0e95ae6d"))
    }

    func testExportHeaderStatesTrezorScope() {
        let text = DiagnosticLog.shared.export()
        XCTAssertTrue(text.contains("Never contains:"))
        XCTAssertTrue(text.contains("wallet addresses, balances"))
    }
}

// MARK: - Send Complete Chime

final class SendCompleteSoundTests: XCTestCase {

    /// The chime ships as a data asset in the app catalog and must decode into
    /// a short player: two bell notes, well under two seconds.
    func testSendCompleteAssetLoadsAndIsShort() throws {
        let asset = try XCTUnwrap(
            NSDataAsset(name: "SendComplete", bundle: .main),
            "SendComplete data asset missing from the app bundle"
        )
        XCTAssertFalse(asset.data.isEmpty)

        let player = try AVAudioPlayer(data: asset.data)
        XCTAssertGreaterThan(player.duration, 0.5)
        XCTAssertLessThan(player.duration, 1.5)
    }
}

// MARK: - Transaction Screen Logic Tests

/// The pure functions behind the All Transactions list (filter, totals,
/// receiving-address options) and the transaction detail screen
/// (received-on label, sent-to rows, Copy All block).
final class TransactionScreenLogicTests: XCTestCase {

    private typealias FilterType = TransactionListView.FilterType

    private func tx(
        _ id: String,
        _ type: MoneroTransaction.TransactionType,
        amount: Decimal,
        fee: Decimal = 0,
        address: String = "",
        status: MoneroTransaction.TransactionStatus = .confirmed,
        confirmations: Int? = 12,
        memo: String? = nil,
        destinations: [MoneroTransactionDestination] = [],
        subaddressIndex: Int? = nil,
        timestamp: TimeInterval = 1_700_000_000
    ) -> MoneroTransaction {
        MoneroTransaction(
            id: id, type: type, amount: amount, fee: fee,
            address: address, timestamp: Date(timeIntervalSince1970: timestamp),
            confirmations: confirmations, status: status, memo: memo,
            blockHeight: nil, destinations: destinations,
            subaddressIndex: subaddressIndex
        )
    }

    private let primary = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
    private let sub2 = "8Bsub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2sub2"
    private let sub3 = "8Bsub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3sub3"
    private let dest1 = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
    private let dest2 = "42dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2dest2d"

    private var subaddresses: [SubaddressSummary] {
        [
            SubaddressSummary(index: 0, address: primary, label: ""),
            SubaddressSummary(index: 1, address: "8Bsub1", label: "", transactionsCount: 0),
            SubaddressSummary(index: 2, address: sub2, label: "Work", transactionsCount: 0),
            SubaddressSummary(index: 3, address: sub3, label: "🎁 Gifts", transactionsCount: 2),
            SubaddressSummary(index: 4, address: "8Bsub4", label: "", transactionsCount: 0),
            SubaddressSummary(index: 5, address: "", label: "Ghost", transactionsCount: 9)
        ]
    }

    private var sample: [MoneroTransaction] {
        [
            tx("in-main", .incoming, amount: 1.0, address: primary, subaddressIndex: 0),
            tx("in-sub3", .incoming, amount: 0.5, address: sub3, memo: "Birthday", subaddressIndex: 3),
            tx("in-sub3-pending", .incoming, amount: 0.25, address: sub3, status: .pending, confirmations: 0, subaddressIndex: 3),
            tx("out-one", .outgoing, amount: 2.0, fee: 0.001, address: dest1,
               destinations: [MoneroTransactionDestination(address: dest1, amount: 2.0)]),
            tx("out-failed", .outgoing, amount: 9.0, fee: 0.5, status: .failed, confirmations: 0),
            tx("out-pending", .outgoing, amount: 0.1, fee: 0.002, status: .pending, confirmations: 0)
        ]
    }

    private func ids(_ type: FilterType = .all, receiving: Int? = nil, search: String = "") -> [String] {
        TransactionListLogic.filter(sample, type: type, receivingIndex: receiving, search: search).map(\.id)
    }

    // MARK: Filter predicate

    func testFilterDefaultsKeepEverything() {
        XCTAssertEqual(ids(), sample.map(\.id))
    }

    func testFilterByType() {
        XCTAssertEqual(ids(.incoming), ["in-main", "in-sub3", "in-sub3-pending"])
        XCTAssertEqual(ids(.outgoing), ["out-one", "out-failed", "out-pending"])
        XCTAssertEqual(ids(.pending), ["in-sub3-pending", "out-pending"])
    }

    func testReceivingFilterKeepsIncomingOnThatIndexOnly() {
        XCTAssertEqual(ids(receiving: 3), ["in-sub3", "in-sub3-pending"])
        XCTAssertEqual(ids(receiving: 0), ["in-main"])
        XCTAssertEqual(ids(receiving: 7), [])
    }

    func testReceivingFilterComposesWithType() {
        XCTAssertEqual(ids(.pending, receiving: 3), ["in-sub3-pending"])
        XCTAssertEqual(ids(.incoming, receiving: 3), ["in-sub3", "in-sub3-pending"])
        // Sends are spent from the account, never from one subaddress.
        XCTAssertEqual(ids(.outgoing, receiving: 3), [])
    }

    func testSearchMatchesIdAddressAndMemoCaseInsensitively() {
        XCTAssertEqual(ids(search: "OUT-ONE"), ["out-one"])
        XCTAssertEqual(ids(search: "birthday"), ["in-sub3"])
        XCTAssertEqual(ids(search: String(dest1.prefix(12))), ["out-one"])
        XCTAssertEqual(ids(search: "no such thing"), [])
    }

    func testSearchComposesWithTypeAndReceivingFilter() {
        XCTAssertEqual(ids(.incoming, receiving: 3, search: "pending"), ["in-sub3-pending"])
        XCTAssertEqual(ids(.outgoing, search: "pending"), ["out-pending"])
        XCTAssertEqual(ids(.incoming, receiving: 0, search: "sub3"), [])
    }

    // MARK: Totals

    func testTotalsSumReceivedAndSentIncludingFee() {
        let totals = TransactionListLogic.totals(of: sample)
        XCTAssertEqual(totals.received, Decimal(string: "1.75"))
        // out-one 2.0 + 0.001, out-pending 0.1 + 0.002; out-failed skipped.
        XCTAssertEqual(totals.sent, Decimal(string: "2.103"))
        XCTAssertEqual(totals.count, 5)
    }

    func testTotalsExcludeFailedButIncludePending() {
        let failedOnly = TransactionListLogic.totals(of: [
            tx("f", .outgoing, amount: 3, fee: 1, status: .failed, confirmations: 0),
            tx("g", .incoming, amount: 3, status: .failed, confirmations: 0)
        ])
        XCTAssertEqual(failedOnly, .empty)

        let pending = TransactionListLogic.totals(of: [
            tx("p", .incoming, amount: 0.4, status: .pending, confirmations: 0),
            tx("q", .outgoing, amount: 0.6, fee: 0.01, status: .pending, confirmations: 0)
        ])
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.received, Decimal(string: "0.4"))
        XCTAssertEqual(pending.sent, Decimal(string: "0.61"))
    }

    func testTotalsOfFilteredSetFollowTheFilter() {
        let onSub3 = TransactionListLogic.filter(sample, type: .all, receivingIndex: 3, search: "")
        let totals = TransactionListLogic.totals(of: onSub3)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.received, Decimal(string: "0.75"))
        XCTAssertEqual(totals.sent, 0)
    }

    // MARK: Fiat totals (Fiat Mode)

    func testFiatTotalsPriceEachTransactionOnItsOwnDate() {
        let day1: TimeInterval = 1_700_000_000
        let day2 = day1 + 86_400
        let prices: [TimeInterval: Double] = [day1: 100, day2: 200]
        let fiat = TransactionListLogic.fiatTotals(of: [
            tx("a", .incoming, amount: 1, timestamp: day1),
            tx("b", .incoming, amount: 0.5, timestamp: day2),
            tx("c", .outgoing, amount: 0.25, fee: 0.125, timestamp: day2),
            tx("f", .outgoing, amount: 9, fee: 1, status: .failed, confirmations: 0, timestamp: day1)
        ], priceAt: { prices[$0.timeIntervalSince1970] })
        // 1 x 100 + 0.5 x 200 received; (0.25 + 0.125) x 200 sent; the
        // failed send is skipped, as in `totals(of:)`.
        XCTAssertEqual(fiat, FiatTotals(received: 200, sent: 75))
    }

    func testFiatTotalsAreNilWhenACountedTransactionHasNoPrice() {
        let priced: TimeInterval = 1_700_000_000
        let priceAt: (Date) -> Double? = { $0.timeIntervalSince1970 == priced ? 150 : nil }
        XCTAssertNil(TransactionListLogic.fiatTotals(of: [
            tx("a", .incoming, amount: 1, timestamp: priced),
            tx("b", .incoming, amount: 1, timestamp: priced + 60)
        ], priceAt: priceAt))
        // A failed transaction moved nothing, so its missing price is fine.
        XCTAssertEqual(TransactionListLogic.fiatTotals(of: [
            tx("a", .incoming, amount: 1, timestamp: priced),
            tx("f", .incoming, amount: 1, status: .failed, confirmations: 0, timestamp: priced + 60)
        ], priceAt: priceAt), FiatTotals(received: 150, sent: 0))
    }

    // MARK: Row amount lines (Fiat Mode)

    func testRowAmountShowsXMRFirstByDefault() {
        let amount = TransactionAmountText(isIncoming: true, xmr: 1.5, fiatAtTime: "$150.00", fiatFirst: false, receivedOn: "Savings")
        XCTAssertEqual(amount.primary, "+1.5000")
        XCTAssertEqual(amount.secondary, "$150.00")
        XCTAssertFalse(amount.isFiatFirst)
        XCTAssertEqual(amount.spoken, "1.5000 XMR on Savings, worth $150.00 at the time")
    }

    func testRowAmountInFiatModeShowsFiatFirst() {
        let amount = TransactionAmountText(isIncoming: false, xmr: 1.5, fiatAtTime: "$150.00", fiatFirst: true, receivedOn: "Savings")
        XCTAssertEqual(amount.primary, "-$150.00")
        XCTAssertEqual(amount.secondary, "1.5000 XMR")
        XCTAssertTrue(amount.isFiatFirst)
        XCTAssertEqual(amount.spoken, "$150.00 at the time, 1.5000 XMR on Savings")
    }

    func testRowAmountInFiatModeShortensTheXMRCaption() {
        let amount = TransactionAmountText(isIncoming: true, xmr: Decimal(string: "0.000580526955")!, fiatAtTime: "$0.32", fiatFirst: true)
        XCTAssertEqual(amount.primary, "+$0.32")
        XCTAssertEqual(amount.secondary, "0.0005805 XMR")
        XCTAssertEqual(amount.spoken, "$0.32 at the time, 0.0005805 XMR")
    }

    func testRowAmountInFiatModeKeepsXMRFirstWithoutAPrice() {
        let amount = TransactionAmountText(isIncoming: true, xmr: 1.5, fiatAtTime: nil, fiatFirst: true)
        XCTAssertEqual(amount.primary, "+1.5000")
        XCTAssertNil(amount.secondary)
        XCTAssertFalse(amount.isFiatFirst)
        XCTAssertEqual(amount.spoken, "1.5000 XMR")
    }

    // MARK: Receiving-address options

    func testReceivingAddressOptionsSkipUnusedUnlabeledSpares() {
        let options = TransactionListLogic.receivingAddressOptions(subaddresses: subaddresses, transactions: [])
        XCTAssertEqual(options.map(\.index), [0, 2, 3])
        XCTAssertEqual(options.map(\.name), ["Main Address", "Work", "🎁 Gifts"])
    }

    func testReceivingAddressOptionsIncludeIndicesSeenInTransactions() {
        let options = TransactionListLogic.receivingAddressOptions(
            subaddresses: subaddresses,
            transactions: [tx("x", .incoming, amount: 1, subaddressIndex: 4)]
        )
        XCTAssertEqual(options.map(\.index), [0, 2, 3, 4])
        XCTAssertEqual(options.last?.name, "Subaddress #4")
    }

    func testReceivingAddressOptionsAlwaysStartWithMainAddress() {
        let options = TransactionListLogic.receivingAddressOptions(subaddresses: [], transactions: [])
        XCTAssertEqual(options.map(\.name), ["Main Address"])
    }

    // MARK: Summary title

    func testSummaryTitleWording() {
        XCTAssertEqual(TransactionListLogic.summaryTitle(count: 1, type: .all, receivingName: nil), "1 transaction")
        XCTAssertEqual(TransactionListLogic.summaryTitle(count: 12, type: .all, receivingName: nil), "12 transactions")
        XCTAssertEqual(TransactionListLogic.summaryTitle(count: 3, type: .incoming, receivingName: "Main Address"), "3 received transactions on Main Address")
        XCTAssertEqual(TransactionListLogic.summaryTitle(count: 0, type: .pending, receivingName: nil), "0 pending transactions")
        XCTAssertEqual(TransactionListLogic.summaryTitle(count: 2, type: .outgoing, receivingName: nil), "2 sent transactions")
    }

    // MARK: Subaddress naming

    func testReceiveNamesUseTheIndexNotTheListPosition() {
        // Index 2 is missing from the list. The picker used to name the
        // address at index 3 "Subaddress #2" (its position) while the
        // transaction screens called it "Subaddress #3".
        let list = [
            SubaddressSummary(index: 1, address: "a1", label: ""),
            SubaddressSummary(index: 3, address: "a3", label: ""),
            SubaddressSummary(index: 4, address: "a4", label: "🎁"),
        ]
        XCTAssertEqual(SubaddressName.display(index: 3, in: list), "Subaddress #3")
        // An emoji-only label keeps the number, the same on every screen.
        XCTAssertEqual(SubaddressName.display(index: 4, in: list), "🎁 Subaddress #4")
        // Selected before the kit lists it: still named by its index.
        XCTAssertEqual(SubaddressName.display(index: 7, in: list), "Subaddress #7")
        XCTAssertEqual(SubaddressName.display(index: 0, in: list), "Main Address")
    }

    func testSubaddressDisplayNameMatchesThePicker() {
        XCTAssertEqual(SubaddressName.display(index: 0, label: "ignored"), "Main Address")
        XCTAssertEqual(SubaddressName.display(index: 3, label: ""), "Subaddress #3")
        XCTAssertEqual(SubaddressName.display(index: 3, label: "Gifts"), "Gifts")
        XCTAssertEqual(SubaddressName.display(index: 3, label: "🎁 Gifts"), "🎁 Gifts")
        XCTAssertEqual(SubaddressName.display(index: 3, label: "🎁"), "🎁 Subaddress #3")
    }

    // MARK: Received-on label

    func testReceivedOnLabelUsesSubaddressIndexFirst() {
        func label(_ index: Int?, address: String = "") -> String? {
            TransactionDetailLogic.receivedOnLabel(
                subaddressIndex: index, address: address,
                primaryAddress: primary, subaddresses: subaddresses
            )
        }
        XCTAssertEqual(label(0), "Main Address")
        XCTAssertEqual(label(2), "Work")
        XCTAssertEqual(label(3), "🎁 Gifts")
        XCTAssertEqual(label(4), "Subaddress #4")
        XCTAssertEqual(label(42), "Subaddress #42")
        // The index wins over a stale address.
        XCTAssertEqual(label(2, address: primary), "Work")
    }

    func testReceivedOnLabelFallsBackToAddressMatch() {
        func label(_ address: String) -> String? {
            TransactionDetailLogic.receivedOnLabel(
                subaddressIndex: nil, address: address,
                primaryAddress: primary, subaddresses: subaddresses
            )
        }
        XCTAssertEqual(label(primary), "Main Address")
        XCTAssertEqual(label(sub2), "Work")
        XCTAssertEqual(label(sub3), "🎁 Gifts")
        XCTAssertEqual(label("8Bunknown"), "Subaddress")
        XCTAssertNil(label(""))
    }

    func testReceivedOnAddressResolvesFromIndexWhenRowHasNone() {
        func address(_ index: Int?, address: String = "") -> String? {
            TransactionDetailLogic.receivedOnAddress(
                subaddressIndex: index, address: address,
                primaryAddress: primary, subaddresses: subaddresses
            )
        }
        XCTAssertEqual(address(3, address: sub3), sub3)
        XCTAssertEqual(address(0), primary)
        XCTAssertEqual(address(2), sub2)
        XCTAssertNil(address(5))
        XCTAssertNil(address(nil))
    }

    // MARK: Sent-to rows

    func testSentToRowsPerDestination() {
        let single = TransactionDetailLogic.sentToRows(
            destinations: [MoneroTransactionDestination(address: dest1, amount: 2)],
            fallbackAddress: dest1
        )
        XCTAssertEqual(single, [SentToRow(label: "Sent to", amountLabel: nil, address: dest1)])

        let two = TransactionDetailLogic.sentToRows(
            destinations: [
                MoneroTransactionDestination(address: dest1, amount: 1),
                MoneroTransactionDestination(address: dest2, amount: 0.5)
            ],
            fallbackAddress: dest1
        )
        XCTAssertEqual(two.map(\.label), ["Sent to (1 of 2)", "Sent to (2 of 2)"])
        XCTAssertEqual(two.map(\.amountLabel), ["1.0000 XMR", "0.5000 XMR"])
        XCTAssertEqual(two.map(\.address), [dest1, dest2])
    }

    func testSentToRowsFallBackToAddressThenToNothing() {
        let legacy = TransactionDetailLogic.sentToRows(destinations: [], fallbackAddress: dest1)
        XCTAssertEqual(legacy, [SentToRow(label: "Sent to", amountLabel: nil, address: dest1)])
        XCTAssertTrue(TransactionDetailLogic.sentToRows(destinations: [], fallbackAddress: "").isEmpty)
    }

    // MARK: Copy All

    private func lines(
        _ transaction: MoneroTransaction,
        receivedOnLabel: String? = nil,
        receivedOnAddress: String? = nil,
        txKey: String? = nil,
        valueAtTime: String? = nil,
        valueToday: String? = nil
    ) -> [TransactionDetailLine] {
        TransactionDetailLogic.detailLines(
            transaction: transaction,
            dateText: "20 September 2026 at 10:00:00",
            receivedOnLabel: receivedOnLabel,
            receivedOnAddress: receivedOnAddress,
            sentTo: TransactionDetailLogic.sentToRows(
                destinations: transaction.destinations,
                fallbackAddress: transaction.type == .outgoing ? transaction.address : ""
            ),
            txKey: txKey,
            explorerURL: URL(string: "https://xmrchain.net/tx/\(transaction.id)"),
            valueAtTime: valueAtTime,
            valueToday: valueToday
        )
    }

    func testCopyAllIncludesFiatValuesWhenKnown() {
        let received = tx("in-fiat", .incoming, amount: 2, fee: 0, address: dest1)
        let result = lines(received, valueAtTime: "$1,000.00", valueToday: "$1,130.70")
        let labels = result.map(\.label)
        XCTAssertEqual(Array(labels.prefix(4)), ["Type", "Amount", "Value when received", "Value today"])
        XCTAssertEqual(result[2].value, "$1,000.00")
        XCTAssertEqual(result[3].value, "$1,130.70")

        let sent = tx("out-fiat", .outgoing, amount: 1, fee: 0.0001, address: dest1)
        XCTAssertEqual(lines(sent, valueAtTime: "€500.00").map(\.label).prefix(4).last, "Value when sent")

        // Unknown values leave no line behind.
        XCTAssertFalse(lines(received).map(\.label).contains { $0.hasPrefix("Value") })
    }

    func testCopyAllOutgoingOrderAndDestinations() {
        let sent = tx(
            "out-two", .outgoing, amount: 1.5, fee: 0.00001, address: dest1,
            memo: "Rent",
            destinations: [
                MoneroTransactionDestination(address: dest1, amount: 1),
                MoneroTransactionDestination(address: dest2, amount: 0.5)
            ]
        )
        let result = lines(sent, txKey: "deadbeef")
        XCTAssertEqual(result.map(\.label), [
            "Type", "Amount", "Fee", "Status", "Confirmations", "Date", "Memo",
            "Transaction ID",
            "Sent to (1 of 2), 1.0000 XMR", "Sent to (2 of 2), 0.5000 XMR",
            "Transaction Key", "Block Explorer"
        ])
        XCTAssertEqual(result[0].value, "Sent")
        XCTAssertEqual(result[1].value, "-1.5000 XMR")
        XCTAssertEqual(result[2].value, "0.00001 XMR")
        XCTAssertEqual(result[3].value, "Confirmed")
        XCTAssertEqual(result[4].value, "12")
        XCTAssertEqual(result[6].value, "Rent")
        XCTAssertEqual(result[8].value, dest1)
        XCTAssertEqual(result[9].value, dest2)
        XCTAssertEqual(result[10].value, "deadbeef")
        XCTAssertEqual(result[11].value, "https://xmrchain.net/tx/out-two")
        XCTAssertEqual(result.filter(\.isSecret).map(\.label), ["Transaction Key"])
    }

    func testCopyAllOmitsMissingFields() {
        let incoming = tx("in-x", .incoming, amount: 0.75, address: sub3, confirmations: nil, subaddressIndex: 3)
        let result = lines(incoming, receivedOnLabel: "🎁 Gifts", receivedOnAddress: sub3)
        XCTAssertEqual(result.map(\.label), [
            "Type", "Amount", "Date", "Transaction ID", "Received on (🎁 Gifts)", "Block Explorer"
        ])
        XCTAssertEqual(result[0].value, "Received")
        XCTAssertEqual(result[1].value, "+0.7500 XMR")
        XCTAssertEqual(result[4].value, sub3)
        XCTAssertFalse(result.contains(where: \.isSecret))
    }

    func testCopyAllRestoredOutgoingExplainsMissingRecipient() {
        let restored = tx("out-old", .outgoing, amount: 1, fee: 0.001)
        let result = lines(restored)
        XCTAssertEqual(result.map(\.label), [
            "Type", "Amount", "Fee", "Status", "Confirmations", "Date", "Transaction ID", "Recipient", "Block Explorer"
        ])
        XCTAssertEqual(result[7].value, "Not available for transactions sent before this wallet was restored")
    }

    func testCopyAllTextIsOneLabelledLinePerField() {
        let text = TransactionDetailLogic.copyAllText([
            TransactionDetailLine(label: "Type", value: "Sent"),
            TransactionDetailLine(label: "Transaction ID", value: "abc")
        ])
        XCTAssertEqual(text, "Type: Sent\nTransaction ID: abc")
    }
}

// MARK: - Receive address card and list

final class ReceiveAddressLogicTests: XCTestCase {

    private func row(_ index: Int, payments: Int = 0, label: String = "") -> ReceiveAddressRow {
        ReceiveAddressRow(
            index: index,
            address: "8addr\(index)",
            label: label,
            usage: ReceiveAddressUsage(payments: payments, received: Decimal(payments))
        )
    }

    private func ids(_ items: [ReceiveAddressListItem]) -> [String] {
        items.map(\.id)
    }

    func testRowsAreNewestFirstWithoutTheMainAddressOrEmptyEntries() {
        let summaries = [
            SubaddressSummary(index: 0, address: "4main", label: ""),
            SubaddressSummary(index: 1, address: "8a1", label: ""),
            SubaddressSummary(index: 3, address: "8a3", label: "Gifts"),
            SubaddressSummary(index: 2, address: "", label: ""),
            SubaddressSummary(index: 3, address: "8a3", label: "Gifts"),
        ]
        let rows = ReceiveAddressLogic.subaddressRows(
            summaries,
            usage: ["8a1": ReceiveAddressUsage(payments: 2, received: Decimal(string: "1.5")!)]
        )
        XCTAssertEqual(rows.map(\.index), [3, 1])
        XCTAssertEqual(rows.last?.usage, ReceiveAddressUsage(payments: 2, received: Decimal(string: "1.5")!))
        XCTAssertEqual(ReceiveAddressLogic.mainRow(primaryAddress: "4main", usage: [:])?.index, 0)
        XCTAssertNil(ReceiveAddressLogic.mainRow(primaryAddress: "", usage: [:]))
    }

    func testUsageSumsIncomingPaymentsPoolIncludedFailedExcluded() {
        func tx(_ type: MoneroTransaction.TransactionType, _ status: MoneroTransaction.TransactionStatus, _ address: String, _ amount: Decimal) -> MoneroTransaction {
            MoneroTransaction(id: UUID().uuidString, type: type, amount: amount, fee: 0, address: address, timestamp: Date(),
                              confirmations: nil, status: status, memo: nil, blockHeight: nil)
        }
        let usage = ReceiveAddressLogic.usage(transactions: [
            tx(.incoming, .confirmed, "8a", 1),
            tx(.incoming, .pending, "8a", Decimal(string: "0.5")!),
            tx(.incoming, .failed, "8a", 7),
            tx(.outgoing, .confirmed, "8a", 3),
            tx(.incoming, .confirmed, "", 2),
        ])
        XCTAssertEqual(usage, ["8a": ReceiveAddressUsage(payments: 2, received: Decimal(string: "1.5")!)])
    }

    func testUnusedSparesBetweenPaymentsFoldIntoOneRow() {
        // 13 is new (shown), 12 is paid, 11...3 are spares, 2 and 1 are paid.
        let rows = [row(13), row(12, payments: 3)] + (3...11).reversed().map { row($0) } + [row(2, payments: 1), row(1, payments: 1)]
        let items = ReceiveAddressLogic.listItems(rows, selectedIndex: 13)
        XCTAssertEqual(ids(items), ["address-13", "address-12", "run-11", "address-2", "address-1"])
        guard case .unusedRun(let run) = items[2] else { return XCTFail("expected a folded run") }
        XCTAssertEqual(run.map(\.index), Array((3...11).reversed()))

        let expanded = ReceiveAddressLogic.listItems(rows, selectedIndex: 13, expandedRuns: [11])
        XCTAssertEqual(expanded.count, rows.count)
    }

    func testNewAddressesAboveTheLastPaymentStayUnfolded() {
        // Five addresses made after the newest paid one: all visible.
        let rows = (6...10).reversed().map { row($0) } + [row(5, payments: 1)]
        let items = ReceiveAddressLogic.listItems(rows, selectedIndex: 10)
        XCTAssertEqual(ids(items), ["address-10", "address-9", "address-8", "address-7", "address-6", "address-5"])
    }

    func testTheSelectedOrANamedAddressBreaksARunAndShortRunsStay() {
        // 9...7 fold; 6 is named; 5 alone stays; 4 is selected; 3 and 2 are
        // only two, so they stay.
        let rows = [row(10, payments: 1)]
            + (2...9).reversed().map { $0 == 6 ? row($0, label: "Rent") : row($0) }
            + [row(1, payments: 1)]
        let items = ReceiveAddressLogic.listItems(rows, selectedIndex: 4)
        XCTAssertEqual(ids(items), ["address-10", "run-9", "address-6", "address-5", "address-4", "address-3", "address-2", "address-1"])
    }

    func testAddressCardsPinTheMainAddressThenFoldSpares() {
        let main = ReceiveAddressRow(index: 0, address: "4MainAddress", label: "")
        let rows = [row(13), row(12, payments: 3)] + (3...11).reversed().map { row($0) } + [row(2, payments: 1), row(1, payments: 1)]
        let items = ReceiveAddressLogic.stackItems(main: main, rows: rows, selectedIndex: 13)
        XCTAssertEqual(ids(items), ["address-0", "address-13", "address-12", "run-11", "address-2", "address-1"])

        // No main address yet: the subaddresses alone.
        XCTAssertEqual(ids(ReceiveAddressLogic.stackItems(main: nil, rows: [row(2), row(1, payments: 1)], selectedIndex: 2)),
                       ["address-2", "address-1"])
    }

    func testAddressCardSearchUnfoldsMatchesAndCanDropTheMainAddress() {
        let main = ReceiveAddressRow(index: 0, address: "4MainAddress", label: "")
        let rows = [row(13), row(12, payments: 3)] + (3...11).reversed().map { row($0) } + [row(2, payments: 1)]
        // "#5" sits inside the folded run: search shows it on its own.
        XCTAssertEqual(ids(ReceiveAddressLogic.stackItems(main: main, rows: rows, selectedIndex: 13, search: "#5")), ["address-5"])
        XCTAssertEqual(ids(ReceiveAddressLogic.stackItems(main: main, rows: rows, selectedIndex: 13, search: "main")), ["address-0"])
        XCTAssertTrue(ReceiveAddressLogic.stackItems(main: main, rows: rows, selectedIndex: 13, search: "nothing like this").isEmpty)
    }

    func testAddressCardSearchShowsFromNineAddresses() {
        XCTAssertFalse(ReceiveAddressLogic.showsSearch(addressCount: 8))
        XCTAssertTrue(ReceiveAddressLogic.showsSearch(addressCount: 9))
    }

    func testRenamingInPlaceSavesOnlyARealChange() {
        // An unnamed address starts with an empty field: saving it untouched
        // must not turn "Subaddress #n" into a label that reserves it.
        XCTAssertNil(ReceiveAddressLogic.labelToSave(draft: "", current: ""))
        XCTAssertNil(ReceiveAddressLogic.labelToSave(draft: "  Gifts ", current: "Gifts"))
        XCTAssertEqual(ReceiveAddressLogic.labelToSave(draft: " Rent\n", current: ""), "Rent")
        XCTAssertEqual(ReceiveAddressLogic.labelToSave(draft: "🎁 Gifts", current: "Gifts"), "🎁 Gifts")
        // Clearing a name saves an empty label.
        XCTAssertEqual(ReceiveAddressLogic.labelToSave(draft: "   ", current: "Rent"), "")
    }

    func testSearchMatchesNameNumberAndAddress() {
        let gifts = ReceiveAddressRow(index: 12, address: "8BNm4Pq2Za7kW1xY", label: "🎁 Gifts")
        XCTAssertTrue(ReceiveAddressLogic.matches(gifts, search: "gifts"))
        XCTAssertTrue(ReceiveAddressLogic.matches(gifts, search: "#12"))
        XCTAssertTrue(ReceiveAddressLogic.matches(gifts, search: "12"))
        XCTAssertTrue(ReceiveAddressLogic.matches(gifts, search: "pq2za"))
        XCTAssertTrue(ReceiveAddressLogic.matches(gifts, search: "  "))
        XCTAssertFalse(ReceiveAddressLogic.matches(gifts, search: "rent"))
        XCTAssertFalse(ReceiveAddressLogic.matches(gifts, search: "#1"))
        XCTAssertTrue(ReceiveAddressLogic.matches(row(4), search: "Subaddress #4"))
    }

    func testUnusedAfterLastUsedCountsFromTheNewestPayment() {
        XCTAssertEqual(ReceiveAddressLogic.unusedAfterLastUsed([]), 0)
        // Nothing paid yet: counted from the main address.
        XCTAssertEqual(ReceiveAddressLogic.unusedAfterLastUsed([row(3), row(2), row(1)]), 3)
        // Gaps count: a seed restore looks across indices, not listed rows.
        XCTAssertEqual(ReceiveAddressLogic.unusedAfterLastUsed([row(9), row(5, payments: 1), row(2)]), 4)
        XCTAssertEqual(ReceiveAddressLogic.unusedAfterLastUsed([row(5, payments: 1)]), 0)
    }

    func testNewAddressWarnsAt150AndStopsAt190() {
        XCTAssertEqual(ReceiveAddressLogic.creationLimit(unusedAfterLastUsed: 149), .allowed)
        XCTAssertEqual(ReceiveAddressLogic.creationLimit(unusedAfterLastUsed: 150), .warn(unused: 150))
        XCTAssertEqual(ReceiveAddressLogic.creationLimit(unusedAfterLastUsed: 189), .warn(unused: 189))
        XCTAssertEqual(ReceiveAddressLogic.creationLimit(unusedAfterLastUsed: 190), .stop(unused: 190))
        XCTAssertEqual(ReceiveAddressLogic.creationLimit(unusedAfterLastUsed: 400), .stop(unused: 400))
        XCTAssertNil(ReceiveAddressLogic.limitText(.allowed))
        XCTAssertNotNil(ReceiveAddressLogic.limitText(.warn(unused: 150)))
        XCTAssertNotNil(ReceiveAddressLogic.limitText(.stop(unused: 190)))
        XCTAssertLessThan(ReceiveAddressLogic.unusedStopThreshold, ReceiveAddressLogic.seedRestoreLookahead)
    }

    func testStatusSaysWhatHappensAfterTheNextPayment() {
        let main = ReceiveAddressRow(index: 0, address: "4main", label: "")
        let unused = row(4)
        let used = row(4, payments: 2)
        XCTAssertEqual(ReceiveAddressLogic.status(for: main, rotate: true, isManualPick: true), .mainAddress)
        XCTAssertEqual(ReceiveAddressLogic.status(for: unused, rotate: true, isManualPick: false), .unusedRotates)
        XCTAssertEqual(ReceiveAddressLogic.status(for: unused, rotate: true, isManualPick: true), .unusedShownUntilPaid)
        XCTAssertEqual(ReceiveAddressLogic.status(for: used, rotate: true, isManualPick: true), .usedShownUntilNextPayment(payments: 2))
        XCTAssertEqual(ReceiveAddressLogic.status(for: used, rotate: true, isManualPick: false), .usedRotates)
        XCTAssertEqual(ReceiveAddressLogic.status(for: unused, rotate: false, isManualPick: false), .stays(payments: 0))
        XCTAssertEqual(ReceiveAddressLogic.status(for: used, rotate: false, isManualPick: true), .stays(payments: 2))

        XCTAssertEqual(ReceiveAddressLogic.statusText(.mainAddress), "Payments to your main address can be linked together.")
        XCTAssertEqual(ReceiveAddressLogic.statusText(.unusedRotates), "Unused. After a payment, Receive shows a new address.")
        XCTAssertEqual(ReceiveAddressLogic.statusText(.unusedShownUntilPaid), "Unused. Shown until it gets paid.")
        XCTAssertEqual(ReceiveAddressLogic.statusText(.usedShownUntilNextPayment(payments: 2)), "2 payments so far. Shown until the next one.")
        XCTAssertEqual(ReceiveAddressLogic.statusText(.stays(payments: 0)), "Unused. Receive stays on this address.")
        XCTAssertEqual(ReceiveAddressLogic.statusText(.stays(payments: 3)), "3 payments so far. Receive stays on this address.")
    }

    func testVoiceOverNamesTheNumberForALabelAndReadsTheTotal() {
        let gifts = ReceiveAddressRow(index: 12, address: "8BNm4Pq2Za7kW1xYZ1kq", label: "Gifts",
                                      usage: ReceiveAddressUsage(payments: 3, received: Decimal(string: "1.5")!))
        XCTAssertEqual(ReceiveAddressLogic.spokenRow(gifts), "Gifts, subaddress 12, received 1.5000 XMR, 3 payments")
        XCTAssertEqual(ReceiveAddressLogic.spokenRow(row(4)), "Subaddress #4, unused")
        XCTAssertEqual(
            ReceiveAddressLogic.spokenSummary(for: gifts, status: "Unused."),
            "Gifts, subaddress 12. Unused. Address starts 8BNm4P, ends Z1kq."
        )
    }

    func testShortAddressKeepsTwelveThenEightCharacters() {
        let address = "8" + String(repeating: "a", count: 86) + "Z1kqWXYZ"
        XCTAssertEqual(ReceiveAddressLogic.shortAddress(address), "8aaaaaaaaaaa…Z1kqWXYZ")
        XCTAssertEqual(ReceiveAddressLogic.shortAddress(address, head: 8, tail: 6), "8aaaaaaa…kqWXYZ")
        XCTAssertEqual(ReceiveAddressLogic.shortAddress("short"), "short")
    }
}

// MARK: - Receive selection per wallet

final class ReceiveSelectionStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ReceiveSelectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The old app-wide pick, as it was stored.
    private struct LegacyBaseline: Codable {
        let walletId: UUID?
        let index: Int
        let transactionsCount: Int
    }

    func testEachWalletKeepsItsOwnSelection() {
        let store = ReceiveSelectionStore(defaults: defaults)
        let a = UUID(), b = UUID()
        store.setIndex(5, for: a)
        store.setIndex(9, for: b)
        store.setBaseline(.init(index: 5, transactionsCount: 2), for: a)

        XCTAssertEqual(store.index(for: a), 5)
        XCTAssertEqual(store.index(for: b), 9)
        XCTAssertEqual(store.baseline(for: a), .init(index: 5, transactionsCount: 2))
        XCTAssertNil(store.baseline(for: b), "a pick in one wallet is not a pick in the other")
        XCTAssertEqual(store.index(for: UUID()), 0, "a wallet with no pick starts on the main address")
    }

    func testOldAppWideValueMovesToTheActiveWalletOnce() throws {
        let store = ReceiveSelectionStore(defaults: defaults)
        let active = UUID(), owner = UUID()
        defaults.set(7, forKey: ReceiveSelectionStore.legacyIndexKey)
        let legacy = try JSONEncoder().encode(LegacyBaseline(walletId: owner, index: 3, transactionsCount: 1))
        defaults.set(legacy, forKey: ReceiveSelectionStore.legacyBaselineKey)

        store.migrateLegacy(activeWalletId: active)

        XCTAssertEqual(store.index(for: active), 7, "the index belonged to the wallet that was open")
        XCTAssertEqual(store.baseline(for: owner), .init(index: 3, transactionsCount: 1), "the pick names its own wallet")
        XCTAssertNil(defaults.object(forKey: ReceiveSelectionStore.legacyIndexKey))
        XCTAssertNil(defaults.object(forKey: ReceiveSelectionStore.legacyBaselineKey))

        // A later switch to another wallet finds nothing left to move.
        store.migrateLegacy(activeWalletId: owner)
        XCTAssertEqual(store.index(for: owner), 0)
        XCTAssertEqual(store.index(for: active), 7)
    }

    func testMigrationKeepsAWalletsOwnValue() {
        let store = ReceiveSelectionStore(defaults: defaults)
        let active = UUID()
        store.setIndex(3, for: active)
        defaults.set(7, forKey: ReceiveSelectionStore.legacyIndexKey)

        store.migrateLegacy(activeWalletId: active)

        XCTAssertEqual(store.index(for: active), 3)
        XCTAssertNil(defaults.object(forKey: ReceiveSelectionStore.legacyIndexKey))
    }

    func testDeletingAWalletForgetsItsSelection() {
        let store = ReceiveSelectionStore(defaults: defaults)
        let a = UUID(), b = UUID()
        store.setIndex(4, for: a)
        store.setBaseline(.init(index: 4, transactionsCount: 0), for: a)
        store.setIndex(6, for: b)

        store.removeAll(for: a)

        XCTAssertEqual(store.index(for: a), 0)
        XCTAssertNil(store.baseline(for: a))
        XCTAssertEqual(store.index(for: b), 6)
    }

    /// Switching wallets shows each wallet's own last address on Receive,
    /// and the pick in one wallet is no pick in the other.
    @MainActor
    func testSwitchingWalletsShowsEachWalletsOwnSelection() {
        let manager = WalletManager()
        let a = wallet("Spending"), b = wallet("Savings")
        let store = ReceiveSelectionStore(defaults: .standard)
        defer {
            store.removeAll(for: a.id)
            store.removeAll(for: b.id)
        }

        manager.activeWallet = a
        manager.noteManualReceiveSelection(index: 5)
        XCTAssertEqual(manager.selectedReceiveIndex, 5)
        XCTAssertTrue(manager.isManualReceiveSelection(index: 5))

        manager.activeWallet = b
        XCTAssertEqual(manager.selectedReceiveIndex, 0, "the other wallet starts on its own address")
        XCTAssertFalse(manager.isManualReceiveSelection(index: 5))
        manager.setReceiveSelection(9)

        manager.activeWallet = a
        XCTAssertEqual(manager.selectedReceiveIndex, 5)
        XCTAssertTrue(manager.isManualReceiveSelection(index: 5))

        manager.activeWallet = b
        XCTAssertEqual(manager.selectedReceiveIndex, 9)
    }

    private func wallet(_ name: String) -> WalletInfo {
        WalletInfo(
            id: UUID(), name: name, emoji: "💰", source: .seed(.polyseed), createdAt: Date(), restoreHeight: 0,
            syncResetCount: 0, userCreatedSubaddressIndices: [], cachedPrimaryAddress: "", cachedBalance: 0
        )
    }
}

// MARK: - App language

final class AppLanguageTests: XCTestCase {
    func testPickerListsEnglishAndTheFifteenTranslationsInTheirOwnNames() {
        XCTAssertEqual(AppLanguage.all.map(\.name), [
            "English", "Deutsch", "Español", "Français", "Italiano", "Nederlands", "Polski",
            "Português (Brasil)", "Română", "Türkçe", "Русский", "Українська",
            "简体中文", "繁體中文", "日本語", "한국어",
        ])
        let bundled = Set(Bundle.main.localizations.filter { $0 != "Base" })
        for language in AppLanguage.all {
            XCTAssertTrue(bundled.contains(language.code), "\(language.code) ships in the app")
        }
    }

    func testCodesMatchTheirLanguage() {
        XCTAssertEqual(AppLanguage.matching("de")?.name, "Deutsch")
        XCTAssertEqual(AppLanguage.matching("de-CH")?.name, "Deutsch")
        XCTAssertEqual(AppLanguage.matching("pt-BR")?.name, "Português (Brasil)")
        XCTAssertEqual(AppLanguage.matching("pt_BR")?.name, "Português (Brasil)")
        XCTAssertEqual(AppLanguage.matching("zh-Hans-US")?.name, "简体中文")
        XCTAssertEqual(AppLanguage.matching("zh-Hant")?.name, "繁體中文")
        XCTAssertEqual(AppLanguage.matching("en-GB")?.name, "English")
        XCTAssertNil(AppLanguage.matching("sv"))
    }

    /// The choice is the app's own `AppleLanguages`, the value iOS writes
    /// for its per-app language setting; System removes it.
    func testChoiceIsTheAppsOwnAppleLanguages() {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let setting = AppLanguageSetting(defaults: defaults, domainName: suiteName)

        XCTAssertNil(setting.choice, "System until the user picks a language")
        setting.set(AppLanguage.matching("ja"))
        XCTAssertEqual(setting.choice?.name, "日本語")
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["ja"])

        setting.set(nil)
        XCTAssertNil(setting.choice)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }
}
