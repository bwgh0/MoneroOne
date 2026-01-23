import XCTest
@testable import MoneroOne

@MainActor
final class WalletManagerTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
    }

    override func tearDown() async throws {
        walletManager.deleteWallet()
        walletManager = nil
    }

    // MARK: - SeedType Enum Tests

    func testSeedTypeWordCounts() async {
        XCTAssertEqual(WalletManager.SeedType.polyseed.wordCount, 16)
        XCTAssertEqual(WalletManager.SeedType.bip39.wordCount, 24)
        XCTAssertEqual(WalletManager.SeedType.legacy.wordCount, 25)
    }

    func testSeedTypeDetectionFromWordCount() async {
        XCTAssertEqual(WalletManager.SeedType.detect(from: 16), .polyseed)
        XCTAssertEqual(WalletManager.SeedType.detect(from: 24), .bip39)
        XCTAssertEqual(WalletManager.SeedType.detect(from: 25), .legacy)
        XCTAssertNil(WalletManager.SeedType.detect(from: 12))
        XCTAssertNil(WalletManager.SeedType.detect(from: 0))
        XCTAssertNil(WalletManager.SeedType.detect(from: 20))
    }

    // MARK: - Polyseed Generation Tests

    func testGeneratePolyseedReturns16Words() async {
        let mnemonic = walletManager.generatePolyseed()

        XCTAssertEqual(mnemonic.count, 16, "Polyseed should generate exactly 16 words")
    }

    func testGeneratePolyseedWordsAreNotEmpty() async {
        let mnemonic = walletManager.generatePolyseed()

        for word in mnemonic {
            XCTAssertFalse(word.isEmpty, "Each polyseed word should not be empty")
        }
    }

    func testGeneratePolyseedProducesUniqueResults() async {
        let mnemonic1 = walletManager.generatePolyseed()
        let mnemonic2 = walletManager.generatePolyseed()

        XCTAssertNotEqual(mnemonic1, mnemonic2, "Each polyseed generation should produce unique mnemonic")
    }

    // MARK: - BIP39 Generation Tests

    func testGenerateBip39SeedReturns24Words() async {
        let mnemonic = walletManager.generateBip39Seed()

        XCTAssertEqual(mnemonic.count, 24, "BIP39 seed should generate exactly 24 words")
    }

    // MARK: - generateNewWallet with SeedType Tests

    func testGenerateNewWalletDefaultsToPolyseed() async {
        let mnemonic = walletManager.generateNewWallet()

        XCTAssertEqual(mnemonic.count, 16, "Default wallet generation should produce 16-word polyseed")
    }

    func testGenerateNewWalletWithPolyseedType() async {
        let mnemonic = walletManager.generateNewWallet(type: .polyseed)

        XCTAssertEqual(mnemonic.count, 16, "Polyseed type should generate 16 words")
    }

    func testGenerateNewWalletWithBip39Type() async {
        let mnemonic = walletManager.generateNewWallet(type: .bip39)

        XCTAssertEqual(mnemonic.count, 24, "BIP39 type should generate 24 words")
    }

    func testGenerateNewWalletWithLegacyType() async {
        let mnemonic = walletManager.generateNewWallet(type: .legacy)

        // Legacy uses BIP39 generation internally (24 words)
        XCTAssertEqual(mnemonic.count, 24, "Legacy type should generate 24 words (uses BIP39 internally)")
    }

    // MARK: - Mnemonic Generation Tests (Backward Compatibility)

    func testGenerateNewWalletWordsAreNotEmpty() async {
        let mnemonic = walletManager.generateNewWallet()

        for word in mnemonic {
            XCTAssertFalse(word.isEmpty, "Each word should not be empty")
        }
    }

    func testGenerateNewWalletProducesUniqueResults() async {
        let mnemonic1 = walletManager.generateNewWallet()
        let mnemonic2 = walletManager.generateNewWallet()

        XCTAssertNotEqual(mnemonic1, mnemonic2, "Each generation should produce unique mnemonic")
    }

    // MARK: - Address Validation Tests

    func testValidMainnetAddressStartingWith4() async {
        // Standard Monero address (95 chars starting with 4)
        let validAddress = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

        XCTAssertTrue(walletManager.isValidAddress(validAddress), "Should accept valid mainnet address starting with 4")
    }

    func testValidSubaddressStartingWith8() async {
        // Subaddress (95 chars starting with 8)
        let validSubaddress = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"

        XCTAssertTrue(walletManager.isValidAddress(validSubaddress), "Should accept valid subaddress starting with 8")
    }

    func testInvalidAddressTooShort() async {
        let shortAddress = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3"

        XCTAssertFalse(walletManager.isValidAddress(shortAddress), "Should reject address that is too short")
    }

    func testInvalidAddressWrongPrefix() async {
        let invalidPrefix = "14AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

        XCTAssertFalse(walletManager.isValidAddress(invalidPrefix), "Should reject address with invalid prefix")
    }

    func testEmptyAddressIsInvalid() async {
        XCTAssertFalse(walletManager.isValidAddress(""), "Should reject empty address")
    }

    // MARK: - Wallet State Tests

    func testInitialStateHasNoWallet() async {
        let freshManager = WalletManager()
        // Note: This depends on keychain state, so may not be reliable in all test environments
        XCTAssertFalse(freshManager.isUnlocked, "Fresh manager should not be unlocked")
    }

    func testInitialBalanceIsZero() async {
        XCTAssertEqual(walletManager.balance, 0, "Initial balance should be zero")
        XCTAssertEqual(walletManager.unlockedBalance, 0, "Initial unlocked balance should be zero")
    }

    func testInitialSyncStateIsIdle() async {
        XCTAssertEqual(walletManager.syncState, .idle, "Initial sync state should be idle")
    }
}
