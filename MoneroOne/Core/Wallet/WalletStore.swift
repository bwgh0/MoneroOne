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
