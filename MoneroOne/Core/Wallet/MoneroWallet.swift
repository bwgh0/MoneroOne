import Foundation
import Combine
import CryptoKit
import MoneroKit
import HsToolKit

/// Wrapper around MoneroKit.Kit for wallet operations
@MainActor
class MoneroWallet: ObservableObject {
    // MARK: - Published State
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var address: String = ""
    @Published var syncState: SyncState = .idle
    @Published var transactions: [MoneroTransaction] = []

    enum SyncState: Equatable {
        case idle
        case connecting
        case syncing(progress: Double, remaining: Int?)
        case synced
        case error(String)
    }

    // MARK: - Private
    private var kit: MoneroKit.Kit?
    private let coinRate: Decimal = 1_000_000_000_000 // pow(10, 12) piconero to XMR
    private let reachabilityManager = ReachabilityManager()

    // MARK: - Initialization

    /// Create a new wallet from seed words
    /// - Parameters:
    ///   - seed: BIP39 seed words
    ///   - restoreHeight: Block height to restore from (0 for full sync)
    ///   - node: Optional custom node
    ///   - resetSuffix: Optional suffix to force new walletId (used for reset sync)
    ///   - networkType: Mainnet or testnet
    func create(seed: [String], restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, resetSuffix: String? = nil, networkType: MoneroKit.NetworkType = .mainnet) throws {
        let walletNode = node ?? defaultNode(for: networkType)
        var walletId = Self.stableWalletId(for: seed)

        // Append reset suffix and network to force new wallet identity
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        if let suffix = resetSuffix {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + suffix + networkSuffix)
        } else if networkType == .testnet {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + networkSuffix)
        }

        kit = try MoneroKit.Kit(
            wallet: .bip39(seed: seed, passphrase: ""),
            account: 0,
            restoreHeight: restoreHeight,
            walletId: walletId,
            node: walletNode,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: nil
        )

        setupKit()
    }

    /// Create watch-only wallet
    func createWatchOnly(address: String, viewKey: String, restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, networkType: MoneroKit.NetworkType = .mainnet) throws {
        let walletNode = node ?? defaultNode(for: networkType)
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let walletId = Self.stableWalletId(for: address + viewKey + networkSuffix)

        kit = try MoneroKit.Kit(
            wallet: .watch(address: address, viewKey: viewKey),
            account: 0,
            restoreHeight: restoreHeight,
            walletId: walletId,
            node: walletNode,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: nil
        )

        setupKit()
    }

    private func defaultNode(for networkType: MoneroKit.NetworkType = .mainnet) -> MoneroKit.Node {
        if networkType == .testnet {
            // Testnet node
            let testnetURL = UserDefaults.standard.string(forKey: "selectedTestnetNodeURL") ?? "http://testnet.xmr.ditatompel.com:28081"
            return MoneroKit.Node(
                url: URL(string: testnetURL)!,
                isTrusted: false,
                login: nil,
                password: nil
            )
        } else {
            // Mainnet - Load from UserDefaults or use default
            let savedURL = UserDefaults.standard.string(forKey: "selectedNodeURL") ?? "https://xmr-node.cakewallet.com:18081"
            return MoneroKit.Node(
                url: URL(string: savedURL)!,
                isTrusted: false,
                login: nil,
                password: nil
            )
        }
    }

    /// Available public nodes
    static let publicNodes: [(name: String, url: String)] = [
        ("CakeWallet", "https://xmr-node.cakewallet.com:18081"),
        ("MoneroWorld", "https://node.moneroworld.com:18089"),
        ("Community Node", "https://nodes.hashvault.pro:18081"),
        ("XMR.to", "https://node.xmr.to:18081")
    ]

    private func setupKit() {
        guard let kit = kit else { return }

        // Set delegate
        kit.delegate = self

        // Get initial values
        updateBalance(kit.balanceInfo)
        address = kit.receiveAddress
        updateSyncState(kit.walletState)

        // Start syncing
        kit.start()
    }

    // MARK: - Lifecycle

    func start() {
        kit?.start()
    }

    func stop() {
        kit?.stop()
    }

    func refresh() {
        kit?.refresh()
    }

    // MARK: - Balance

    private func updateBalance(_ info: MoneroKit.BalanceInfo) {
        balance = Decimal(info.all) / coinRate
        unlockedBalance = Decimal(info.unlocked) / coinRate
    }

    // MARK: - Sync State

    private func updateSyncState(_ state: MoneroKit.WalletState) {
        switch state {
        case .connecting:
            syncState = .connecting
        case .synced:
            syncState = .synced
        case .syncing(let progress, let remainingBlocksCount):
            let progressPercent = Double(min(99, progress))
            syncState = .syncing(progress: progressPercent, remaining: remainingBlocksCount > 0 ? remainingBlocksCount : nil)
        case .notSynced(let error):
            syncState = .error(friendlyErrorMessage(for: error))
        case .idle:
            syncState = .idle
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let errorString = String(describing: error)

        // Check for common MoneroKit errors
        if errorString.contains("WalletStateError") {
            if errorString.contains("error 1") {
                return "Unable to connect to node. Please try a different node in Settings."
            } else if errorString.contains("error 2") {
                return "Node returned invalid response. Try another node."
            } else if errorString.contains("error 3") {
                return "Connection timeout. Check your internet connection."
            }
        }

        if errorString.lowercased().contains("timeout") {
            return "Connection timed out. Try again or switch nodes."
        }

        if errorString.lowercased().contains("network") || errorString.lowercased().contains("internet") {
            return "Network error. Check your connection."
        }

        if errorString.lowercased().contains("refused") || errorString.lowercased().contains("unreachable") {
            return "Node unavailable. Try a different node."
        }

        // Fallback to a cleaner message
        return "Sync failed. Tap Retry or try a different node."
    }

    // MARK: - Transactions

    func fetchTransactions() {
        guard let kit = kit else { return }

        let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: 100)
        transactions = txInfos.map { mapTransaction($0) }
    }

    private func mapTransaction(_ info: MoneroKit.TransactionInfo) -> MoneroTransaction {
        let amount = Decimal(info.amount) / coinRate
        let fee = Decimal(info.fee) / coinRate

        return MoneroTransaction(
            id: info.hash,
            type: info.type == .incoming ? .incoming : .outgoing,
            amount: amount,
            fee: fee,
            address: info.recipientAddress ?? "",
            timestamp: Date(timeIntervalSince1970: Double(info.timestamp)),
            confirmations: 0, // Would need block height comparison
            status: info.isFailed ? .failed : .confirmed,
            memo: info.memo
        )
    }

    // MARK: - Send

    func estimateFee(to address: String, amount: Decimal, priority: SendPriority = .default) async throws -> Decimal {
        guard let kit = kit else { throw WalletError.notUnlocked }

        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        let fee = try await kit.estimateFee(address: address, amount: .value(piconero), priority: priority)
        return Decimal(fee) / coinRate
    }

    func send(to address: String, amount: Decimal, priority: SendPriority = .default, memo: String? = nil) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }

        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        try await kit.send(to: address, amount: .value(piconero), priority: priority, memo: memo)
        // MoneroKit send doesn't return a hash directly - fetch from recent transactions
        fetchTransactions()
        return transactions.first?.id ?? ""
    }

    func sendAll(to address: String, priority: SendPriority = .default, memo: String? = nil) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }

        try await kit.send(to: address, amount: .all, priority: priority, memo: memo)
        fetchTransactions()
        return transactions.first?.id ?? ""
    }

    // MARK: - Validation

    static func isValidAddress(_ address: String, networkType: MoneroKit.NetworkType = .mainnet) -> Bool {
        MoneroKit.Kit.isValid(address: address, networkType: networkType)
    }

    // MARK: - Restore Height

    static func restoreHeight(for date: Date) -> UInt64 {
        UInt64(MoneroKit.RestoreHeight.getHeight(date: date))
    }

    // MARK: - Wallet ID

    /// Generate a stable wallet ID from seed words - ensures sync data persists across app restarts
    private static func stableWalletId(for seed: [String]) -> String {
        stableWalletId(for: seed.joined(separator: " "))
    }

    /// Generate a stable wallet ID from any string (seed phrase or address+viewKey)
    private static func stableWalletId(for identifier: String) -> String {
        let data = Data(identifier.utf8)
        let hash = SHA256.hash(data: data)
        // Use first 16 bytes as a UUID-like identifier
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MoneroKitDelegate

extension MoneroWallet: MoneroKitDelegate {
    nonisolated func subAddressesUpdated(subaddresses: [MoneroKit.SubAddress]) {
        // Not using subaddresses for now
    }

    nonisolated func balanceDidChange(balanceInfo: MoneroKit.BalanceInfo) {
        Task { @MainActor in
            updateBalance(balanceInfo)
        }
    }

    nonisolated func walletStateDidChange(state: MoneroKit.WalletState) {
        Task { @MainActor in
            updateSyncState(state)
        }
    }

    nonisolated func transactionsUpdated(inserted: [MoneroKit.TransactionInfo], updated: [MoneroKit.TransactionInfo]) {
        Task { @MainActor in
            fetchTransactions()
        }
    }
}

// MARK: - Transaction Model

struct MoneroTransaction: Identifiable, Equatable {
    let id: String
    let type: TransactionType
    let amount: Decimal
    let fee: Decimal
    let address: String
    let timestamp: Date
    let confirmations: Int
    let status: TransactionStatus
    let memo: String?

    enum TransactionType {
        case incoming
        case outgoing
    }

    enum TransactionStatus {
        case pending
        case confirmed
        case failed
    }

    static func == (lhs: MoneroTransaction, rhs: MoneroTransaction) -> Bool {
        lhs.id == rhs.id
    }
}
