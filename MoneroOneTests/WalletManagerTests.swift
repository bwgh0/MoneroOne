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

    // MARK: - Receive Address Rotation Rule

    private func slot(_ index: Int, used: Int = 0, labeled: Bool = false) -> WalletManager.ReceiveAddressSlot {
        WalletManager.ReceiveAddressSlot(index: index, transactionsCount: used, isLabeled: labeled)
    }

    func testRotationOffKeepsExistingSelection() {
        let slots = [slot(0, used: 3), slot(1, used: 1), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, subaddresses: slots, rotate: false), 1)
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 0, subaddresses: slots, rotate: false), 0)
    }

    func testRotationOffFallsBackToPrimaryWhenSelectionIsMissing() {
        let slots = [slot(0), slot(1)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 7, subaddresses: slots, rotate: false), 0)
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 3, subaddresses: [], rotate: false), 0)
    }

    func testRotationNeverAutoSelectsPrimary() {
        // Fresh wallet: nothing used, nothing labeled, primary unused.
        let slots = [slot(0), slot(1)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 0, subaddresses: slots, rotate: true), 1)
        // Only the primary is free: the rule still asks for a subaddress.
        XCTAssertNil(WalletManager.nextReceiveIndex(selected: 0, subaddresses: [slot(0), slot(1, used: 1)], rotate: true))
    }

    func testRotationMovesOffUsedSelection() {
        let slots = [slot(0, used: 2), slot(1, used: 1), slot(2), slot(3)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, subaddresses: slots, rotate: true), 2)
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 0, subaddresses: slots, rotate: true), 2)
    }

    func testRotationKeepsUnusedSelectionAfterLastUsedOrLabeled() {
        let slots = [slot(0, used: 1), slot(1, used: 1), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 2, subaddresses: slots, rotate: true), 2)
    }

    func testRotationSkipsLabeledUnusedAddress() {
        // Index 2 is reserved by its label; the rule lands after it.
        let slots = [slot(0, used: 1), slot(1, used: 1), slot(2, labeled: true), slot(3)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, subaddresses: slots, rotate: true), 3)
    }

    func testRotationPicksFirstAddressAfterLastUsedOrLabeled() {
        // Unused 2 and 3 sit below the labeled 5, so they are skipped.
        let slots = [slot(0, used: 1), slot(1, used: 1), slot(2), slot(3), slot(5, labeled: true), slot(6), slot(7)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, subaddresses: slots, rotate: true), 6)
    }

    func testRotationAsksForNewAddressWhenNothingFollowsLastUsedOrLabeled() {
        let allUsed = [slot(0, used: 1), slot(1, used: 1), slot(2, used: 1)]
        XCTAssertNil(WalletManager.nextReceiveIndex(selected: 2, subaddresses: allUsed, rotate: true))
        let lastIsLabeled = [slot(0, used: 1), slot(1), slot(2, labeled: true)]
        XCTAssertNil(WalletManager.nextReceiveIndex(selected: 1, subaddresses: lastIsLabeled, rotate: true))
    }

    func testManualPickIsHonoredUntilItReceives() {
        // Picked the primary while it already had 3 payments.
        var slots = [slot(0, used: 3), slot(1, used: 1), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 0, selectedBaselineCount: 3, subaddresses: slots, rotate: true), 0)
        // A fourth payment arrives (pool counts): the rule moves on.
        slots = [slot(0, used: 4), slot(1, used: 1), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 0, selectedBaselineCount: 3, subaddresses: slots, rotate: true), 2)
    }

    func testManualPickOfLabeledAddressIsHonored() {
        let slots = [slot(0, used: 1), slot(1, labeled: true), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, selectedBaselineCount: 0, subaddresses: slots, rotate: true), 1)
        let afterPayment = [slot(0, used: 1), slot(1, used: 1, labeled: true), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 1, selectedBaselineCount: 0, subaddresses: afterPayment, rotate: true), 2)
    }

    func testReceiveUsageCountsIncomingPerAddressPoolIncludedFailedExcluded() {
        func tx(_ id: String, _ type: MoneroTransaction.TransactionType, _ status: MoneroTransaction.TransactionStatus, _ address: String) -> MoneroTransaction {
            MoneroTransaction(id: id, type: type, amount: 1, fee: 0, address: address, timestamp: Date(),
                              confirmations: nil, status: status, memo: nil, blockHeight: nil)
        }
        let counts = WalletManager.receiveUsageCounts(transactions: [
            tx("a", .incoming, .confirmed, "8addrA"),
            tx("b", .incoming, .pending, "8addrA"),
            tx("c", .incoming, .confirmed, "8addrB"),
            tx("d", .incoming, .failed, "8addrC"),
            tx("e", .outgoing, .confirmed, "8addrD"),
            tx("f", .incoming, .confirmed, ""),
        ])
        XCTAssertEqual(counts, ["8addrA": 2, "8addrB": 1])
    }

    func testSelectionMissingInSwitchedWalletFallsThroughToRule() {
        // Index 7 was picked in another wallet; this wallet only has 0...2.
        let slots = [slot(0, used: 1), slot(1, used: 1), slot(2)]
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 7, selectedBaselineCount: 0, subaddresses: slots, rotate: true), 2)
        XCTAssertEqual(WalletManager.nextReceiveIndex(selected: 7, subaddresses: slots, rotate: true), 2)
    }
}

// MARK: - Wallet Order Tests

/// Store order is the switcher's display order: loading never sorts, a switch
/// never moves a row, and a drag rewrites the persisted array in place.
@MainActor
final class WalletOrderTests: XCTestCase {

    private let store = WalletStore()
    private var savedWallets: Data?
    private var savedActiveId: String?

    override func setUp() async throws {
        savedWallets = UserDefaults.standard.data(forKey: "one.monero.walletStore.wallets")
        savedActiveId = UserDefaults.standard.string(forKey: "one.monero.walletStore.activeWalletId")
        store.deleteAll()
    }

    override func tearDown() async throws {
        store.deleteAll()
        if let savedWallets {
            UserDefaults.standard.set(savedWallets, forKey: "one.monero.walletStore.wallets")
        }
        if let savedActiveId {
            UserDefaults.standard.set(savedActiveId, forKey: "one.monero.walletStore.activeWalletId")
        }
    }

    private func wallet(_ name: String) -> WalletInfo {
        WalletInfo(
            id: UUID(),
            name: name,
            source: .seed(.polyseed),
            createdAt: Date(),
            restoreHeight: 0,
            syncResetCount: 0,
            userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: nil,
            cachedBalance: nil
        )
    }

    func testReorderedFollowsIdsIgnoresUnknownAndAppendsMissing() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C"), d = wallet("D")
        let list = [a, b, c, d]

        XCTAssertEqual(WalletStore.reordered(list, by: [c.id, a.id, b.id, d.id]).map(\.id),
                       [c.id, a.id, b.id, d.id])
        // Unknown ids are skipped; wallets left out keep their order at the end.
        XCTAssertEqual(WalletStore.reordered(list, by: [UUID(), d.id, b.id]).map(\.id),
                       [d.id, b.id, a.id, c.id])
        // A duplicate id places the wallet once.
        XCTAssertEqual(WalletStore.reordered(list, by: [b.id, b.id]).map(\.id),
                       [b.id, a.id, c.id, d.id])
        XCTAssertEqual(WalletStore.reordered(list, by: []).map(\.id), list.map(\.id))
    }

    func testReorderedMovingBeforeAndToEnd() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C"), d = wallet("D")
        let list = [a, b, c, d]

        // One item before another, in both directions.
        XCTAssertEqual(WalletStore.reordered(list, moving: [d.id], before: b.id).map(\.id),
                       [a.id, d.id, b.id, c.id])
        XCTAssertEqual(WalletStore.reordered(list, moving: [a.id], before: c.id).map(\.id),
                       [b.id, a.id, c.id, d.id])
        XCTAssertEqual(WalletStore.reordered(list, moving: [d.id], before: a.id).map(\.id),
                       [d.id, a.id, b.id, c.id])
        // To the end.
        XCTAssertEqual(WalletStore.reordered(list, moving: [b.id], before: nil).map(\.id),
                       [a.id, c.id, d.id, b.id])
        // Sources not in the list are ignored; a move of only unknown ids is a no-op.
        XCTAssertEqual(WalletStore.reordered(list, moving: [UUID(), c.id], before: a.id).map(\.id),
                       [c.id, a.id, b.id, d.id])
        XCTAssertEqual(WalletStore.reordered(list, moving: [UUID()], before: a.id).map(\.id),
                       list.map(\.id))
        // Moved items keep their list order whatever order they were picked up in.
        XCTAssertEqual(WalletStore.reordered(list, moving: [d.id, b.id], before: a.id).map(\.id),
                       [b.id, d.id, a.id, c.id])
        XCTAssertEqual(WalletStore.reordered(list, moving: [c.id, a.id], before: nil).map(\.id),
                       [b.id, d.id, a.id, c.id])
        // An unknown `before` appends; an empty move or a drop onto a moving item changes nothing.
        XCTAssertEqual(WalletStore.reordered(list, moving: [a.id], before: UUID()).map(\.id),
                       [b.id, c.id, d.id, a.id])
        XCTAssertEqual(WalletStore.reordered(list, moving: [], before: b.id).map(\.id), list.map(\.id))
        XCTAssertEqual(WalletStore.reordered(list, moving: [b.id], before: b.id).map(\.id), list.map(\.id))
        // Wallets themselves come through untouched, not just their ids.
        XCTAssertEqual(WalletStore.reordered(list, moving: [d.id], before: b.id).map(\.name),
                       ["A", "D", "B", "C"])
    }

    func testReorderWalletsPersistsOrderAndKeepsActiveId() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C")
        store.saveWallets([a, b, c])
        store.setActiveWalletId(b.id)

        store.reorderWallets([c.id, UUID(), a.id])

        XCTAssertEqual(store.loadWallets().map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(store.loadWallets().map(\.name), ["C", "A", "B"])
        XCTAssertEqual(store.activeWalletId, b.id, "Reordering must not touch the active wallet")
    }

    func testLoadingKeepsStoreOrderAndSwitchingDoesNotMoveRows() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C")
        store.saveWallets([c, a, b])
        store.setActiveWalletId(b.id)

        let manager = WalletManager()
        XCTAssertEqual(manager.wallets.map(\.id), [c.id, a.id, b.id], "Loading must keep store order")
        XCTAssertEqual(manager.activeWallet?.id, b.id)

        XCTAssertNotNil(manager.prepareSwitchToWallet(id: c.id))
        XCTAssertEqual(manager.activeWallet?.id, c.id)
        XCTAssertEqual(manager.wallets.map(\.id), [c.id, a.id, b.id], "A switch must not move any row")
        XCTAssertEqual(store.loadWallets().map(\.id), [c.id, a.id, b.id])
    }

    func testMoveWalletsPersistsOffsetsAndLeavesActiveAlone() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C")
        store.saveWallets([a, b, c])
        store.setActiveWalletId(a.id)
        let manager = WalletManager()

        manager.moveWallets(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(manager.wallets.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(manager.activeWallet?.id, a.id)
        XCTAssertEqual(store.activeWalletId, a.id)

        manager.moveWallet(id: a.id, to: 1)
        XCTAssertEqual(manager.wallets.map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [b.id, a.id, c.id])

        manager.moveWallet(id: c.id, to: 0)
        XCTAssertEqual(manager.wallets.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [c.id, b.id, a.id])

        // Unknown ids and no-op moves change nothing.
        manager.moveWallet(id: UUID(), to: 0)
        manager.moveWallet(id: c.id, to: 0)
        manager.moveWallet(id: a.id, to: 99)
        XCTAssertEqual(manager.wallets.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(store.activeWalletId, a.id)
    }

    func testApplyReorderPersistsThroughStoreAndLeavesActiveAlone() {
        let a = wallet("A"), b = wallet("B"), c = wallet("C")
        store.saveWallets([a, b, c])
        store.setActiveWalletId(a.id)
        let manager = WalletManager()

        manager.applyReorder(moving: [a.id], before: c.id)
        XCTAssertEqual(manager.wallets.map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(manager.activeWallet?.id, a.id)
        XCTAssertEqual(store.activeWalletId, a.id)

        manager.applyReorder(moving: [b.id], before: nil)
        XCTAssertEqual(manager.wallets.map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [a.id, c.id, b.id])

        // Unknown sources and no-op drops change nothing, on disk or in memory.
        manager.applyReorder(moving: [UUID()], before: a.id)
        manager.applyReorder(moving: [a.id], before: c.id)
        manager.applyReorder(moving: [b.id], before: b.id)
        XCTAssertEqual(manager.wallets.map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(store.loadWallets().map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(manager.activeWallet?.id, a.id)
        XCTAssertEqual(store.activeWalletId, a.id)
    }

}

// MARK: - Needs Restore Tests

/// A device backup or Quick Start brings the wallet list (UserDefaults) to a
/// new iPhone without the ThisDeviceOnly keychain items. These tests make
/// that state by deleting a wallet's keychain items after it is saved.
@MainActor
final class NeedsRestoreTests: XCTestCase {

    private let pin = "123456"
    private let keychain = KeychainStorage()
    private let store = WalletStore()

    override func setUp() async throws {
        UserDefaults.standard.set(false, forKey: "isTestnet")
        WalletManager().deleteAllWallets()
        keychain.resetFailedAttempts()
    }

    override func tearDown() async throws {
        WalletManager().deleteAllWallets()
        keychain.resetFailedAttempts()
        UserDefaults.standard.removeObject(forKey: "isTestnet")
    }

    /// Saves seed wallets the way Create Wallet does, in this order. The
    /// last one is active.
    private func addSeedWallets(_ names: [String], restoreHeight: UInt64? = nil) throws -> [(id: UUID, phrase: [String])] {
        let manager = WalletManager()
        return try names.map { name in
            let phrase = manager.generatePolyseed()
            try manager.addWallet(name: name, mnemonic: phrase, pin: pin, restoreHeight: restoreHeight)
            return (try XCTUnwrap(manager.activeWallet?.id), phrase)
        }
    }

    /// What a device backup leaves: the wallet row without its keychain items.
    private func dropKeys(_ id: UUID) {
        keychain.deleteSeed(walletId: id)
    }

    private func row(_ id: UUID) -> WalletInfo? {
        store.loadWallets().first { $0.id == id }
    }

    private func moneroKitCacheEntries() -> Set<String> {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let dir = appSupport.appendingPathComponent("MoneroKit")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    // MARK: Detection

    func testWalletsWithKeysDoNotNeedRestore() throws {
        _ = try addSeedWallets(["A", "B"])

        let manager = WalletManager()
        XCTAssertTrue(manager.walletsNeedingRestore.isEmpty)
        XCTAssertFalse(manager.allWalletsNeedRestore)
    }

    func testEveryWalletWithoutKeysNeedsRestore() throws {
        let made = try addSeedWallets(["A", "B"])
        made.forEach { dropKeys($0.id) }

        let manager = WalletManager()
        XCTAssertEqual(manager.walletsNeedingRestore, Set(made.map(\.id)))
        XCTAssertTrue(manager.allWalletsNeedRestore, "ContentView shows the restore screen, not the PIN screen")
    }

    func testMissingPinVerifierAloneMeansNeedsRestore() throws {
        let a = try addSeedWallets(["A"])[0]
        keychain.deleteKeychainAccount("one.monero.MoneroOne.wallet.\(a.id.uuidString).pinhash")

        XCTAssertTrue(WalletManager().needsRestore(a.id))
    }

    func testSomeWalletsWithoutKeysUnlockWithAWalletThatHasKeys() throws {
        let made = try addSeedWallets(["A", "B"])
        XCTAssertEqual(store.activeWalletId, made[1].id)
        dropKeys(made[1].id)

        let manager = WalletManager()
        XCTAssertEqual(manager.walletsNeedingRestore, [made[1].id])
        XCTAssertFalse(manager.allWalletsNeedRestore, "The PIN screen stays")
        XCTAssertEqual(manager.activeWallet?.id, made[0].id, "The PIN must unlock a wallet that has its keys")
        XCTAssertEqual(store.activeWalletId, made[0].id)
        XCTAssertEqual(manager.wallets.map(\.id), made.map(\.id), "Rows keep their order")
    }

    /// A device backup carries no wallet2 files, so files still on this
    /// iPhone (developer team transfer) pick the restore screen's neutral text.
    func testWalletFilesLeftOnThisIPhoneAreDetected() throws {
        let a = try addSeedWallets(["A"])[0]
        dropKeys(a.id)
        let cacheId = try XCTUnwrap(row(a.id)?.derivedWalletId)
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let dir = appSupport.appendingPathComponent("MoneroKit").appendingPathComponent(cacheId)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(WalletManager().needsRestoreWalletFilesRemain, "New iPhone from a device backup: no wallet2 files")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(WalletManager().needsRestoreWalletFilesRemain, "Same iPhone, keys gone: the files remain")
    }

    // MARK: Never a wrong PIN

    func testMissingPinVerifierIsNeverAWrongPin() throws {
        let a = try addSeedWallets(["A"])[0]
        keychain.deleteKeychainAccount("one.monero.MoneroOne.wallet.\(a.id.uuidString).pinhash")

        for _ in 0..<7 {
            XCTAssertThrowsError(try keychain.getSeed(pin: "000000", walletId: a.id)) { error in
                guard let keychainError = error as? KeychainError, case .keysMissing = keychainError else {
                    return XCTFail("Expected keysMissing, got \(error)")
                }
            }
        }
        XCTAssertFalse(keychain.isLockedOut, "A missing verifier must not count toward the lockout")
    }

    func testUnlockWithoutKeysThrowsKeysMissingNotInvalidPin() async throws {
        let a = try addSeedWallets(["A"])[0]
        dropKeys(a.id)

        let manager = WalletManager()
        do {
            try await manager.unlock(pin: pin)
            XCTFail("Unlock must fail without keys")
        } catch WalletError.keysMissing {
            // Expected: the restore screen handles this wallet.
        }
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertFalse(keychain.isLockedOut)
    }

    // MARK: Matching a phrase to a wallet

    func testPhraseMatchesItsWalletByCacheId() async throws {
        let made = try addSeedWallets(["A", "B"])
        made.forEach { dropKeys($0.id) }
        let manager = WalletManager()

        let match = try await manager.matchWalletNeedingRestore(mnemonic: made[1].phrase)
        XCTAssertEqual(match.walletId, made[1].id)
        XCTAssertEqual(match.derivedWalletId, row(made[1].id)?.derivedWalletId)

        let targeted = try await manager.matchWalletNeedingRestore(mnemonic: made[0].phrase, walletId: made[0].id)
        XCTAssertEqual(targeted.walletId, made[0].id)
    }

    func testPhraseOfAnotherWalletIsRejected() async throws {
        let made = try addSeedWallets(["A", "B"])
        made.forEach { dropKeys($0.id) }
        let manager = WalletManager()

        do {
            _ = try await manager.matchWalletNeedingRestore(mnemonic: made[0].phrase, walletId: made[1].id)
            XCTFail("A's phrase must not restore B")
        } catch WalletError.phraseMismatch(let name) {
            XCTAssertEqual(name, "B")
        }

        do {
            _ = try await manager.matchWalletNeedingRestore(mnemonic: manager.generatePolyseed())
            XCTFail("A new phrase matches no wallet")
        } catch WalletError.phraseMatchesNoWallet {
            // Expected.
        }
    }

    func testPhraseOfWalletThatHasKeysIsADuplicate() async throws {
        let made = try addSeedWallets(["A", "B"])
        dropKeys(made[1].id)
        let manager = WalletManager()

        do {
            _ = try await manager.matchWalletNeedingRestore(mnemonic: made[0].phrase)
            XCTFail("A still has its keys")
        } catch WalletError.duplicateWallet(let name) {
            XCTAssertEqual(name, "A")
        }
    }

    // MARK: Restoring into the row

    func testRestoreIntoWalletKeepsItsRowAndCacheId() async throws {
        let made = try addSeedWallets(["A", "B"], restoreHeight: 3_100_000)
        made.forEach { dropKeys($0.id) }
        let manager = WalletManager()
        let before = try XCTUnwrap(row(made[1].id))

        let match = try await manager.matchWalletNeedingRestore(mnemonic: made[1].phrase)
        try manager.restoreWalletNeedingRestore(match, mnemonic: made[1].phrase, pin: "654321", name: before.name, emoji: before.emoji)

        let after = try XCTUnwrap(row(made[1].id))
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.restoreHeight, 3_100_000)
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertEqual(after.syncResetCount, before.syncResetCount)
        XCTAssertEqual(after.source, before.source)
        XCTAssertEqual(after.derivedWalletId, before.derivedWalletId, "walletId lockstep: the cache id must not change")
        XCTAssertEqual(store.loadWallets().map(\.id), made.map(\.id), "No new row, same order")
        XCTAssertEqual(store.activeWalletId, made[1].id)
        XCTAssertEqual(manager.activeWallet?.id, made[1].id)
        XCTAssertEqual(manager.walletsNeedingRestore, [made[0].id])
        XCTAssertEqual(try keychain.getSeed(pin: "654321", walletId: made[1].id), made[1].phrase.joined(separator: " "))
        XCTAssertEqual(WalletManager().walletsNeedingRestore, [made[0].id], "The restored wallet stays restored on the next launch")
    }

    /// The same wallet in another phrase format hashes to another cache id,
    /// so its primary address must prove the match. Runs a throwaway wallet2.
    func testPhraseInAnotherFormatMatchesByAddress() async throws {
        let phrase = WalletManager().generatePolyseed()
        let networkType = WalletManager().networkType
        let cachesBefore = moneroKitCacheEntries()
        let address = try await MoneroWallet().probePrimaryAddress(seed: phrase, networkType: networkType)
        XCTAssertEqual(address.count, 95, "Primary address, got \(address)")
        XCTAssertTrue(address.hasPrefix("4"))
        XCTAssertEqual(moneroKitCacheEntries(), cachesBefore, "The throwaway wallet2 leaves no cache behind")

        let oldCacheId = String(repeating: "0", count: 32)
        let id = UUID(), other = UUID()
        store.addWallet(WalletInfo(
            id: id, name: "Old", source: .seeded(wordCount: 25), createdAt: Date(), restoreHeight: 0,
            syncResetCount: 0, userCreatedSubaddressIndices: [], cachedPrimaryAddress: address,
            cachedBalance: nil, derivedWalletId: oldCacheId
        ))
        store.addWallet(WalletInfo(
            id: other, name: "Other", source: .seeded(wordCount: 25), createdAt: Date(), restoreHeight: 0,
            syncResetCount: 0, userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A",
            cachedBalance: nil, derivedWalletId: String(repeating: "1", count: 32)
        ))
        store.setActiveWalletId(id)

        let manager = WalletManager()
        XCTAssertEqual(manager.walletsNeedingRestore, [id, other])

        do {
            _ = try await manager.matchWalletNeedingRestore(mnemonic: phrase, walletId: other)
            XCTFail("The address shows the phrase is not Other's")
        } catch WalletError.phraseMismatch(let name) {
            XCTAssertEqual(name, "Other")
        }

        let match = try await manager.matchWalletNeedingRestore(mnemonic: phrase)
        XCTAssertEqual(match.walletId, id)
        XCTAssertNotEqual(match.derivedWalletId, oldCacheId)

        try manager.restoreWalletNeedingRestore(match, mnemonic: phrase, pin: pin, name: "Old", emoji: "\u{1F4B0}")
        let after = try XCTUnwrap(row(id))
        XCTAssertEqual(after.derivedWalletId, match.derivedWalletId, "The cache id create() derives from this phrase")
        XCTAssertEqual(after.source, .seeded(wordCount: 16))
        XCTAssertEqual(after.cachedPrimaryAddress, address)
        XCTAssertEqual(manager.walletsNeedingRestore, [other])
    }

    // MARK: PIN change and removal

    func testChangePinSkipsWalletsThatNeedRestore() throws {
        let made = try addSeedWallets(["A", "B"])
        dropKeys(made[1].id)
        let manager = WalletManager()

        try manager.reencryptAllWallets(oldPin: pin, newPin: "654321")

        XCTAssertEqual(try keychain.getSeed(pin: "654321", walletId: made[0].id), made[0].phrase.joined(separator: " "))
        XCTAssertTrue(keychain.walletKeysMissing(walletId: made[1].id, holdsSeed: true))
    }

    func testRemoveAllRemovesWalletsThatNeedRestore() throws {
        let made = try addSeedWallets(["A", "B"])
        dropKeys(made[1].id)
        let manager = WalletManager()

        manager.deleteAllWallets()

        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertTrue(manager.walletsNeedingRestore.isEmpty)
        XCTAssertFalse(manager.allWalletsNeedRestore, "Onboarding, not the restore screen")
        XCTAssertNil(manager.activeWallet)
        XCTAssertTrue(store.loadWallets().isEmpty)
        XCTAssertTrue(keychain.walletKeysMissing(walletId: made[0].id, holdsSeed: true))
    }

    func testDeletingActiveWalletMovesToAWalletWithKeys() throws {
        let made = try addSeedWallets(["A", "B", "C"])
        dropKeys(made[0].id)
        let manager = WalletManager()
        XCTAssertEqual(manager.activeWallet?.id, made[2].id)

        manager.deleteWallet(id: made[2].id)

        XCTAssertEqual(manager.activeWallet?.id, made[1].id, "Skip A: it needs restore")
    }

    func testDeletingAWalletRemovesTheSendRecordsThatNameIt() throws {
        let made = try addSeedWallets(["A", "B", "C"])
        let manager = WalletManager()
        let records = SendRecordStore()
        records.record(SendRecord(txid: "send-to-a-b", fromWalletId: made[0].id, toWalletId: made[1].id))
        records.record(SendRecord(txid: "send-to-a-c", fromWalletId: made[0].id, toWalletId: made[2].id))
        defer { records.clearAll() }

        manager.deleteWallet(id: made[1].id)

        XCTAssertNil(records.record(txid: "send-to-a-b"))
        XCTAssertNotNil(records.record(txid: "send-to-a-c"))
    }

    func testRemoveAllWipesTheSendRecords() throws {
        let made = try addSeedWallets(["A", "B"])
        let manager = WalletManager()
        let records = SendRecordStore()
        records.record(SendRecord(txid: "send-to-wipe", fromWalletId: made[0].id, toWalletId: made[1].id))

        manager.deleteAllWallets()

        XCTAssertNil(records.record(txid: "send-to-wipe"))
    }
}
