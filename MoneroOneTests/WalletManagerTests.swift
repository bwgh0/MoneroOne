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

    // MARK: - Mnemonic Generation Tests

    func testGenerateNewWalletReturns24Words() async {
        let mnemonic = walletManager.generateNewWallet()

        XCTAssertEqual(mnemonic.count, 24, "Should generate 24-word BIP39 mnemonic")
    }

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
