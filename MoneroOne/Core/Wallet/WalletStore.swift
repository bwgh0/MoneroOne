import Foundation

/// Persists wallet list and active wallet ID in UserDefaults.
/// Seeds stay in keychain — this only stores non-sensitive metadata.
struct WalletStore {
    private static let walletsKey = "one.monero.walletStore.wallets"
    private static let activeWalletIdKey = "one.monero.walletStore.activeWalletId"

    // MARK: - Wallet List

    func loadWallets() -> [WalletInfo] {
        guard let data = UserDefaults.standard.data(forKey: Self.walletsKey) else { return [] }
        return (try? JSONDecoder().decode([WalletInfo].self, from: data)) ?? []
    }

    func saveWallets(_ wallets: [WalletInfo]) {
        if let data = try? JSONEncoder().encode(wallets) {
            UserDefaults.standard.set(data, forKey: Self.walletsKey)
        }
    }

    func addWallet(_ wallet: WalletInfo) {
        var wallets = loadWallets()
        wallets.append(wallet)
        saveWallets(wallets)
    }

    func removeWallet(id: UUID) {
        var wallets = loadWallets()
        wallets.removeAll { $0.id == id }
        saveWallets(wallets)

        // If the removed wallet was active, clear active ID
        if activeWalletId == id {
            setActiveWalletId(wallets.first?.id)
        }
    }

    func updateWallet(_ wallet: WalletInfo) {
        var wallets = loadWallets()
        if let index = wallets.firstIndex(where: { $0.id == wallet.id }) {
            wallets[index] = wallet
            saveWallets(wallets)
        }
    }

    // MARK: - Order

    /// Rewrites the persisted list in the order of `ids`. Store order is the
    /// switcher's display order: insertion order until the user drags a row.
    /// Unknown ids are ignored, wallets missing from `ids` keep their relative
    /// order at the end, and the active wallet id is left alone.
    @discardableResult
    func reorderWallets(_ ids: [UUID]) -> [WalletInfo] {
        let reordered = Self.reordered(loadWallets(), by: ids)
        saveWallets(reordered)
        return reordered
    }

    /// Pure reorder behind `reorderWallets(_:)`, exposed for tests.
    static func reordered(_ wallets: [WalletInfo], by ids: [UUID]) -> [WalletInfo] {
        var remaining = wallets
        var result: [WalletInfo] = []
        result.reserveCapacity(wallets.count)
        for id in ids {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: index))
        }
        return result + remaining
    }

    /// Pure reorder behind `WalletManager.applyReorder(moving:before:)`, the
    /// shape of SwiftUI's `ReorderDifference`: the wallets whose ids are in
    /// `moving` come out of `wallets` and go back in before the wallet
    /// `before`, or at the end when it is nil. The moved wallets keep their
    /// order in the list, whatever order they were picked up in. Ids not in
    /// the list are ignored; a `before` that is not in the list appends, and
    /// one that is itself moving changes nothing.
    static func reordered(_ wallets: [WalletInfo], moving: [UUID], before: UUID?) -> [WalletInfo] {
        let movingIds = Set(moving)
        if let before, movingIds.contains(before) { return wallets }
        var moved: [WalletInfo] = []
        var rest: [WalletInfo] = []
        for wallet in wallets {
            if movingIds.contains(wallet.id) {
                moved.append(wallet)
            } else {
                rest.append(wallet)
            }
        }
        guard !moved.isEmpty else { return wallets }
        let index = before.flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.endIndex
        rest.insert(contentsOf: moved, at: index)
        return rest
    }

    // MARK: - Active Wallet

    var activeWalletId: UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.activeWalletIdKey) else { return nil }
        return UUID(uuidString: str)
    }

    func setActiveWalletId(_ id: UUID?) {
        if let id = id {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activeWalletIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeWalletIdKey)
        }
    }

    // MARK: - Next Wallet Name

    func nextWalletName(existing: [WalletInfo]) -> String {
        var n = existing.count + 1
        let existingNames = Set(existing.map(\.name))
        while existingNames.contains("Wallet \(n)") {
            n += 1
        }
        return "Wallet \(n)"
    }

    // MARK: - Reset

    func deleteAll() {
        UserDefaults.standard.removeObject(forKey: Self.walletsKey)
        UserDefaults.standard.removeObject(forKey: Self.activeWalletIdKey)
    }
}
