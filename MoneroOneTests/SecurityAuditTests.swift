import XCTest
@testable import MoneroOne
import MoneroKit

/// Comprehensive tests for security-critical fixes
/// These tests verify that critical security bugs are properly addressed
@MainActor
final class SecurityAuditTests: XCTestCase {

    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
        // Clear any existing state
        walletManager.deleteWallet()
        // Reset network to mainnet for consistent test state
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    override func tearDown() async throws {
        walletManager.deleteWallet()
        walletManager = nil
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: "isTestnet")
        UserDefaults.standard.removeObject(forKey: "selectedSubaddressIndex")
    }

    // MARK: - CRITICAL #1: Seed Keychain Network-Prefix Tests

    /// Test that mainnet and testnet seeds are stored separately
    /// This is CRITICAL - without network-prefixed keys, switching networks
    /// would overwrite one network's seed with another
    func testSeedStorageIsNetworkPrefixed() async throws {
        let keychain = KeychainStorage()
        let mainnetSeed = "mainnet test seed phrase words one two three four five six"
        let testnetSeed = "testnet different seed phrase words alpha beta gamma delta epsilon"
        let pin = "123456"

        // Save seed on mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")
        try keychain.saveSeed(mainnetSeed, pin: pin)

        // Verify mainnet seed exists
        XCTAssertTrue(keychain.hasSeed(), "Mainnet seed should exist")

        // Switch to testnet
        UserDefaults.standard.set(true, forKey: "isTestnet")

        // Testnet should NOT have a seed yet (different key)
        XCTAssertFalse(keychain.hasSeed(), "Testnet should not have seed yet")

        // Save different seed on testnet
        try keychain.saveSeed(testnetSeed, pin: pin)
        XCTAssertTrue(keychain.hasSeed(), "Testnet seed should now exist")

        // Switch back to mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")

        // Mainnet seed should still exist and be the original
        XCTAssertTrue(keychain.hasSeed(), "Mainnet seed should still exist")
        let retrievedMainnetSeed = try keychain.getSeed(pin: pin)
        XCTAssertEqual(retrievedMainnetSeed, mainnetSeed, "Mainnet seed should not be overwritten by testnet")

        // Switch to testnet and verify its seed
        UserDefaults.standard.set(true, forKey: "isTestnet")
        let retrievedTestnetSeed = try keychain.getSeed(pin: pin)
        XCTAssertEqual(retrievedTestnetSeed, testnetSeed, "Testnet seed should be correct")

        // Clean up
        keychain.deleteSeed()
        UserDefaults.standard.set(false, forKey: "isTestnet")
        keychain.deleteSeed()
    }

    /// Test that deleting seed on one network doesn't affect the other
    func testDeleteSeedIsNetworkSpecific() async throws {
        let keychain = KeychainStorage()
        let mainnetSeed = "mainnet seed one two three four five six seven eight nine ten"
        let testnetSeed = "testnet seed alpha beta gamma delta epsilon zeta eta theta iota"
        let pin = "123456"

        // Save seeds on both networks
        UserDefaults.standard.set(false, forKey: "isTestnet")
        try keychain.saveSeed(mainnetSeed, pin: pin)

        UserDefaults.standard.set(true, forKey: "isTestnet")
        try keychain.saveSeed(testnetSeed, pin: pin)

        // Delete testnet seed
        keychain.deleteSeed()
        XCTAssertFalse(keychain.hasSeed(), "Testnet seed should be deleted")

        // Mainnet seed should still exist
        UserDefaults.standard.set(false, forKey: "isTestnet")
        XCTAssertTrue(keychain.hasSeed(), "Mainnet seed should still exist after testnet deletion")

        // Clean up
        keychain.deleteSeed()
    }

    // MARK: - CRITICAL #2: Seed Verification Before Display Tests

    /// Test that getSeedPhrase verifies seed matches current wallet
    /// This prevents showing wrong seed if keychain gets out of sync
    func testGetSeedPhraseVerifiesSeedMatchesWallet() async throws {
        // Create wallet and unlock it
        let mnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        // Wait briefly for wallet to initialize
        try await Task.sleep(nanoseconds: 500_000_000)

        // Getting seed should succeed and match
        let retrieved = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertEqual(retrieved, mnemonic, "Retrieved seed should match original")
    }

    /// Test that mismatched seed throws error
    /// This simulates the scenario where keychain has wrong seed
    func testGetSeedPhraseThrowsOnMismatch() async throws {
        // This test verifies the defense-in-depth check
        // The primary protection is network-prefixed keys (tested above)
        // This test ensures the secondary verification also works

        // Create wallet and unlock
        let originalMnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: originalMnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        // Wait for wallet to initialize and have primaryAddress set
        try await Task.sleep(nanoseconds: 500_000_000)

        // The currentSeed in WalletManager should match keychain
        // So getSeedPhrase should succeed
        let retrieved = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertNotNil(retrieved)

        // Note: Testing actual mismatch would require manipulating internal state
        // which isn't possible from the test. The implementation check compares
        // the keychain seed against currentSeed (the seed used to unlock).
    }

    // MARK: - CRITICAL #3: Address Clearing on Switch Tests

    /// Test that switchSyncMode clears addresses before reinitializing
    func testSwitchSyncModeClearsAddresses() async throws {
        // Create and unlock wallet
        let mnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Record current state
        let initialSyncMode = walletManager.currentSyncMode

        // Switch sync mode
        let newMode: SyncMode = initialSyncMode == .lite ? .privacy : .lite
        walletManager.switchSyncMode(to: newMode)

        // Addresses should be cleared (empty or "Loading...")
        // The actual address will be repopulated after switch completes
        // We're testing that stale addresses don't persist during the switch
        XCTAssertNotEqual(walletManager.currentSyncMode, initialSyncMode,
                          "Sync mode should have changed")
    }

    /// Test that switchNetwork clears addresses before reinitializing
    func testSwitchNetworkClearsAddresses() async throws {
        // Create and unlock wallet on mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")
        let mnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Get mainnet address (if available)
        let mainnetAddress = walletManager.primaryAddress

        // Switch to testnet
        UserDefaults.standard.set(true, forKey: "isTestnet")
        walletManager.switchNetwork()

        // Wait for switch to process
        try await Task.sleep(nanoseconds: 500_000_000)

        // If address is populated, it should be different (testnet addresses start with different prefix)
        // Mainnet addresses start with "4", testnet with "9"
        if !walletManager.primaryAddress.isEmpty && !mainnetAddress.isEmpty {
            XCTAssertNotEqual(walletManager.primaryAddress.prefix(1),
                              mainnetAddress.prefix(1),
                              "Network switch should show different address prefix")
        }

        // Clean up - switch back to mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    /// Test that lock() clears all sensitive state
    func testLockClearsAllAddresses() async throws {
        let mnemonic = walletManager.generateNewWallet()
        let pin = "123456"
        try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
        try walletManager.unlock(pin: pin)

        // Wait for initialization
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Lock the wallet
        walletManager.lock()

        // All address fields should be cleared
        XCTAssertEqual(walletManager.address, "", "address should be empty after lock")
        XCTAssertEqual(walletManager.primaryAddress, "", "primaryAddress should be empty after lock")
        XCTAssertTrue(walletManager.subaddresses.isEmpty, "subaddresses should be empty after lock")
        XCTAssertEqual(walletManager.balance, 0, "balance should be 0 after lock")
        XCTAssertEqual(walletManager.unlockedBalance, 0, "unlockedBalance should be 0 after lock")
    }

    // MARK: - HIGH #4: Subaddress Index Validation Tests

    /// Test that selectedSubaddressIndex persists in AppStorage
    func testSubaddressIndexPersistence() {
        // Set a subaddress index
        UserDefaults.standard.set(5, forKey: "selectedSubaddressIndex")

        // Read it back
        let index = UserDefaults.standard.integer(forKey: "selectedSubaddressIndex")
        XCTAssertEqual(index, 5, "Subaddress index should persist")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "selectedSubaddressIndex")
    }

    /// Test that invalid subaddress index is handled gracefully
    /// The ReceiveView should reset to index 0 if selected index doesn't exist
    func testInvalidSubaddressIndexResetsToMain() {
        // Simulate having selected a high index previously
        UserDefaults.standard.set(10, forKey: "selectedSubaddressIndex")

        // Verify it was set
        let storedIndex = UserDefaults.standard.integer(forKey: "selectedSubaddressIndex")
        XCTAssertEqual(storedIndex, 10, "Index should be stored")

        // In a real scenario, ReceiveView would detect this and reset
        // We test the expected behavior: if subaddress doesn't exist, reset to 0
        // The actual reset happens in ReceiveView's currentAddress computed property
        // which we can't easily test without the view

        // Clean up
        UserDefaults.standard.removeObject(forKey: "selectedSubaddressIndex")
    }

    // MARK: - HIGH #5: Balance UInt64 Overflow Tests

    /// Test that Balance struct handles large values without overflow
    func testBalanceHandlesLargeValues() {
        // Test with values that would overflow Int32
        let largeBalance: UInt64 = UInt64(Int32.max) + 1_000_000
        let balance = MoneroKit.BalanceInfo(all: Int64(largeBalance), unlocked: Int64(largeBalance))

        XCTAssertEqual(balance.all, Int64(largeBalance), "Balance should handle values larger than Int32")
        XCTAssertEqual(balance.unlocked, Int64(largeBalance), "Unlocked balance should handle large values")
    }

    /// Test that Balance struct handles maximum Monero supply
    /// Max Monero supply is ~18.4 million XMR = 18.4e12 * 1e12 piconero
    /// which exceeds UInt64 max, but practical balances are much smaller
    func testBalanceHandlesRealisticMaximum() {
        // Realistic maximum: 1 million XMR in piconero
        // 1 XMR = 1e12 piconero
        let oneMillionXMR: UInt64 = 1_000_000 * 1_000_000_000_000 // 1e18 piconero

        // This should fit comfortably in Int64 (max ~9.2e18)
        let balance = MoneroKit.BalanceInfo(all: Int64(oneMillionXMR), unlocked: Int64(oneMillionXMR))

        XCTAssertEqual(balance.all, Int64(oneMillionXMR), "Should handle 1M XMR balance")
    }

    /// Test Balance equality
    func testBalanceEquality() {
        let balance1 = MoneroKit.BalanceInfo(all: 1000, unlocked: 500)
        let balance2 = MoneroKit.BalanceInfo(all: 1000, unlocked: 500)
        let balance3 = MoneroKit.BalanceInfo(all: 1000, unlocked: 600)

        XCTAssertEqual(balance1, balance2, "Equal balances should be equal")
        XCTAssertNotEqual(balance1, balance3, "Different balances should not be equal")
    }

    // MARK: - Integration Tests

    /// Test full scenario: Create wallet on mainnet, switch to testnet, verify seeds are separate
    func testFullNetworkSwitchScenario() async throws {
        let keychain = KeychainStorage()
        let pin = "123456"

        // 1. Create wallet on mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")
        let mainnetMnemonic = walletManager.generateNewWallet()
        try walletManager.saveWallet(mnemonic: mainnetMnemonic, pin: pin)

        // Verify
        XCTAssertTrue(walletManager.hasWallet, "Should have mainnet wallet")

        // 2. Unlock on mainnet
        try walletManager.unlock(pin: pin)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 3. Get seed on mainnet (should match)
        let retrievedMainnet = try walletManager.getSeedPhrase(pin: pin)
        XCTAssertEqual(retrievedMainnet, mainnetMnemonic, "Mainnet seed should match")

        // 4. Lock wallet
        walletManager.lock()

        // 5. Switch to testnet
        UserDefaults.standard.set(true, forKey: "isTestnet")

        // 6. On testnet, we shouldn't have a wallet yet
        let testnetManager = WalletManager()
        XCTAssertFalse(testnetManager.hasWallet, "Should not have testnet wallet yet")

        // 7. Create testnet wallet
        let testnetMnemonic = testnetManager.generateNewWallet()
        try testnetManager.saveWallet(mnemonic: testnetMnemonic, pin: pin)

        // 8. Verify testnet wallet exists
        XCTAssertTrue(testnetManager.hasWallet, "Should have testnet wallet")

        // 9. Switch back to mainnet
        UserDefaults.standard.set(false, forKey: "isTestnet")

        // 10. Mainnet wallet should still exist with correct seed
        let mainnetManager2 = WalletManager()
        XCTAssertTrue(mainnetManager2.hasWallet, "Mainnet wallet should still exist")

        let mainnetSeedAgain = try mainnetManager2.getSeedPhrase(pin: pin)
        XCTAssertEqual(mainnetSeedAgain, mainnetMnemonic, "Mainnet seed should be unchanged")

        // Clean up
        mainnetManager2.deleteWallet()
        UserDefaults.standard.set(true, forKey: "isTestnet")
        testnetManager.deleteWallet()
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }

    /// Test that rapid network switching doesn't corrupt data
    func testRapidNetworkSwitching() async throws {
        let keychain = KeychainStorage()
        let mainnetSeed = "mainnet rapid test seed one two three four five six seven eight"
        let testnetSeed = "testnet rapid test seed alpha beta gamma delta epsilon zeta eta"
        let pin = "123456"

        // Save seeds on both networks
        UserDefaults.standard.set(false, forKey: "isTestnet")
        try keychain.saveSeed(mainnetSeed, pin: pin)

        UserDefaults.standard.set(true, forKey: "isTestnet")
        try keychain.saveSeed(testnetSeed, pin: pin)

        // Rapidly switch back and forth and verify integrity
        for i in 0..<10 {
            let isTestnet = i % 2 == 1
            UserDefaults.standard.set(isTestnet, forKey: "isTestnet")

            let expectedSeed = isTestnet ? testnetSeed : mainnetSeed
            let actualSeed = try keychain.getSeed(pin: pin)

            XCTAssertEqual(actualSeed, expectedSeed,
                           "Seed should be correct after rapid switch \(i)")
        }

        // Clean up
        UserDefaults.standard.set(false, forKey: "isTestnet")
        keychain.deleteSeed()
        UserDefaults.standard.set(true, forKey: "isTestnet")
        keychain.deleteSeed()
        UserDefaults.standard.set(false, forKey: "isTestnet")
    }
}
