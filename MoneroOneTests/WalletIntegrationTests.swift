import XCTest
@testable import MoneroOne

@MainActor
final class WalletIntegrationTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
    }

    override func tearDown() async throws {
        walletManager.deleteWallet()
        walletManager = nil
    }

    // MARK: - Wallet Creation Flow Tests

    func testWalletCreationFlow() async throws {
        // Generate mnemonic
        let mnemonic = walletManager.generateNewWallet()
        XCTAssertEqual(mnemonic.count, 24)

        // Save wallet
        let pin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        // Verify wallet exists
        XCTAssertTrue(walletManager.hasWallet)
    }

    func testWalletCreationWithRestoreHeight() async throws {
        let mnemonic = walletManager.generateNewWallet()
        let pin = "1234"
        let restoreHeight: UInt64 = 2500000

        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin, restoreHeight: restoreHeight)

        let savedHeight = UserDefaults.standard.integer(forKey: "restoreHeight")
        XCTAssertEqual(UInt64(savedHeight), restoreHeight)
    }

    // MARK: - Wallet Restore Flow Tests

    func testWalletRestoreWithValidMnemonic() async throws {
        // Use a test mnemonic (not a real wallet!)
        let testMnemonic = [
            "abandon", "abandon", "abandon", "abandon", "abandon", "abandon",
            "abandon", "abandon", "abandon", "abandon", "abandon", "about"
        ]
        let pin = "1234"

        // This should not throw for a valid BIP39 mnemonic
        try walletManager.restoreWallet(mnemonic: testMnemonic, pin: pin)

        XCTAssertTrue(walletManager.hasWallet)
    }

    func testWalletRestoreWithInvalidMnemonicThrows() async {
        let invalidMnemonic = ["invalid", "words", "that", "are", "not", "valid"]
        let pin = "1234"

        do {
            try walletManager.restoreWallet(mnemonic: invalidMnemonic, pin: pin)
            XCTFail("Should throw for invalid mnemonic")
        } catch {
            XCTAssertTrue(error is WalletError)
        }
    }

    func testWalletRestoreWithDate() async throws {
        let testMnemonic = [
            "abandon", "abandon", "abandon", "abandon", "abandon", "abandon",
            "abandon", "abandon", "abandon", "abandon", "abandon", "about"
        ]
        let pin = "1234"
        let restoreDate = Date(timeIntervalSince1970: 1600000000) // Sept 2020

        try walletManager.restoreWallet(mnemonic: testMnemonic, pin: pin, restoreDate: restoreDate)

        // Restore height should be set
        let savedHeight = UserDefaults.standard.integer(forKey: "restoreHeight")
        XCTAssertGreaterThan(savedHeight, 0)
    }

    // MARK: - Unlock Flow Tests

    func testUnlockWithCorrectPin() async throws {
        // First create a wallet
        let mnemonic = walletManager.generateNewWallet()
        let pin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        // Now try to unlock
        try walletManager.unlock(pin: pin)

        XCTAssertTrue(walletManager.isUnlocked)
    }

    func testUnlockWithWrongPinThrows() async throws {
        // First create a wallet
        let mnemonic = walletManager.generateNewWallet()
        let correctPin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: correctPin)

        // Try to unlock with wrong pin
        let wrongPin = "9999"
        do {
            try walletManager.unlock(pin: wrongPin)
            XCTFail("Should throw for wrong PIN")
        } catch {
            XCTAssertTrue(error is WalletError)
        }
    }

    // MARK: - Lock/Unlock State Tests

    func testLockClearsState() async throws {
        // Create and unlock wallet
        let mnemonic = walletManager.generateNewWallet()
        let pin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        XCTAssertTrue(walletManager.isUnlocked)

        // Lock wallet
        walletManager.lock()

        XCTAssertFalse(walletManager.isUnlocked)
        XCTAssertEqual(walletManager.balance, 0)
        XCTAssertEqual(walletManager.unlockedBalance, 0)
        XCTAssertEqual(walletManager.address, "")
        XCTAssertEqual(walletManager.syncState, .idle)
    }

    // MARK: - Delete Wallet Tests

    func testDeleteWalletRemovesData() async throws {
        // Create wallet
        let mnemonic = walletManager.generateNewWallet()
        let pin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)

        XCTAssertTrue(walletManager.hasWallet)

        // Delete wallet
        walletManager.deleteWallet()

        XCTAssertFalse(walletManager.hasWallet)
        XCTAssertFalse(walletManager.isUnlocked)
    }

    // MARK: - Seed Recovery Tests

    func testGetSeedPhraseReturnsCorrectWords() async throws {
        let originalMnemonic = walletManager.generateNewWallet()
        let pin = "1234"
        try walletManager.saveWallet(mnemonic: originalMnemonic, pin: pin)

        let retrievedMnemonic = try walletManager.getSeedPhrase(pin: pin)

        XCTAssertNotNil(retrievedMnemonic)
        XCTAssertEqual(retrievedMnemonic, originalMnemonic)
    }

    func testGetSeedPhraseWithWrongPinFails() async throws {
        let mnemonic = walletManager.generateNewWallet()
        let correctPin = "1234"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: correctPin)

        let wrongPin = "9999"

        do {
            let result = try walletManager.getSeedPhrase(pin: wrongPin)
            // If it doesn't throw, it should return nil or empty
            XCTAssertTrue(result == nil || result != mnemonic, "Should not return seed for wrong PIN")
        } catch {
            // Expected - throwing is also acceptable behavior
        }
    }

    // MARK: - Transaction State Tests

    func testInitialTransactionsEmpty() async {
        XCTAssertTrue(walletManager.transactions.isEmpty)
    }

    // MARK: - Error Handling Tests

    func testSendWithoutUnlockThrows() async {
        do {
            _ = try await walletManager.send(to: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A", amount: 1.0)
            XCTFail("Should throw when wallet not unlocked")
        } catch {
            XCTAssertEqual((error as? WalletError), .notUnlocked)
        }
    }

    func testEstimateFeeWithoutUnlockThrows() async {
        do {
            _ = try await walletManager.estimateFee(to: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A", amount: 1.0)
            XCTFail("Should throw when wallet not unlocked")
        } catch {
            XCTAssertEqual((error as? WalletError), .notUnlocked)
        }
    }
}
