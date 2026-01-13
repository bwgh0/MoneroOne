import Foundation
import Combine
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
    func create(seed: [String], restoreHeight: UInt64 = 0) throws {
        let node = defaultNode()

        kit = try MoneroKit.Kit(
            wallet: .bip39(seed: seed, passphrase: ""),
            account: 0,
            restoreHeight: restoreHeight,
            walletId: UUID().uuidString,
            node: node,
            networkType: .mainnet,
            reachabilityManager: reachabilityManager,
            logger: nil
        )

        setupKit()
    }

    /// Create watch-only wallet
    func createWatchOnly(address: String, viewKey: String, restoreHeight: UInt64 = 0) throws {
        let node = defaultNode()

        kit = try MoneroKit.Kit(
            wallet: .watch(address: address, viewKey: viewKey),
            account: 0,
            restoreHeight: restoreHeight,
            walletId: UUID().uuidString,
            node: node,
            networkType: .mainnet,
            reachabilityManager: reachabilityManager,
            logger: nil
        )

        setupKit()
    }

    private func defaultNode() -> MoneroKit.Node {
        MoneroKit.Node(
            url: URL(string: "https://node.moneroworld.com:18089")!,
            isTrusted: false,
            login: nil,
            password: nil
        )
    }

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
            syncState = .error(error.localizedDescription)
        case .idle:
            syncState = .idle
        }
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

    static func isValidAddress(_ address: String) -> Bool {
        MoneroKit.Kit.isValid(address: address, networkType: .mainnet)
    }

    // MARK: - Restore Height

    static func restoreHeight(for date: Date) -> UInt64 {
        UInt64(MoneroKit.RestoreHeight.getHeight(date: date))
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
