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
    @Published var subaddresses: [MoneroKit.SubAddress] = []

    /// Secret view key (hex string) - used for lite mode
    var secretViewKey: String? {
        guard let walletCredentials = walletCredentials else { return nil }
        // Get private view key (not spend key)
        return try? MoneroKit.Kit.key(wallet: walletCredentials, privateKey: true, spendKey: false)
    }

    /// Primary address (index 0) - from storage (pre-computed)
    var primaryAddress: String {
        kit?.primaryAddress ?? ""
    }

    /// Primary address directly from wallet2 runtime - use for light wallet mode
    var runtimePrimaryAddress: String {
        kit?.runtimePrimaryAddress ?? ""
    }

    // Store wallet credentials for view key extraction
    private var walletCredentials: MoneroKit.MoneroWallet?

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

        // Store credentials for view key extraction
        let credentials = MoneroKit.MoneroWallet.bip39(seed: seed, passphrase: "")
        walletCredentials = credentials

        kit = try MoneroKit.Kit(
            wallet: credentials,
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

    /// Create wallet in light wallet mode connected to LWS server
    /// The LWS handles blockchain scanning; wallet2 fetches outputs from LWS endpoints
    /// - Parameters:
    ///   - seed: BIP39 seed words
    ///   - lwsURL: Light Wallet Server URL
    ///   - restoreHeight: Block height to restore from
    ///   - resetSuffix: Optional suffix to force new walletId
    ///   - networkType: Mainnet or testnet
    func createLightWallet(seed: [String], lwsURL: URL, restoreHeight: UInt64 = 0, resetSuffix: String? = nil, networkType: MoneroKit.NetworkType = .mainnet) throws {
        // Create light wallet node - wallet2 will use LWS endpoints for outputs
        let lightNode = MoneroKit.Node(
            url: lwsURL,
            isTrusted: true,
            isLightWallet: true
        )

        var walletId = Self.stableWalletId(for: seed)

        // Append reset suffix and network to force new wallet identity
        let modeSuffix = "_light"
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        if let suffix = resetSuffix {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + suffix + modeSuffix + networkSuffix)
        } else {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + modeSuffix + networkSuffix)
        }

        // Store credentials for view key extraction
        let credentials = MoneroKit.MoneroWallet.bip39(seed: seed, passphrase: "")
        walletCredentials = credentials

        kit = try MoneroKit.Kit(
            wallet: credentials,
            account: 0,
            restoreHeight: restoreHeight,
            walletId: walletId,
            node: lightNode,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: nil
        )

        setupKit()
    }

    private func defaultNode(for networkType: MoneroKit.NetworkType = .mainnet) -> MoneroKit.Node {
        if networkType == .testnet {
            // Testnet node (port 28081)
            let testnetURL = UserDefaults.standard.string(forKey: "selectedTestnetNodeURL") ?? Self.testnetNodes.first!.url
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

    /// Available public mainnet nodes
    static let publicNodes: [(name: String, url: String)] = [
        ("CakeWallet", "https://xmr-node.cakewallet.com:18081"),
        ("MoneroWorld", "https://node.moneroworld.com:18089"),
        ("Community Node", "https://nodes.hashvault.pro:18081"),
        ("XMR.to", "https://node.xmr.to:18081")
    ]

    /// Available public testnet nodes (port 28081/28089)
    /// Note: Testnet nodes are often unreliable. MoneroKit doesn't support stagenet.
    static let testnetNodes: [(name: String, url: String)] = [
        ("Monero Project", "http://testnet.xmr-tw.org:28081"),
        ("MoneroDevs", "http://node.monerodevs.org:28089"),
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

    deinit {
        NSLog("[MoneroWallet] DEINIT called - wallet being deallocated!")
        Thread.callStackSymbols.prefix(15).forEach { NSLog("[MoneroWallet] deinit stack: \($0)") }
    }

    func start() {
        kit?.start()
    }

    func stop() {
        NSLog("[MoneroWallet] stop() called")
        Thread.callStackSymbols.prefix(10).forEach { NSLog("[MoneroWallet] stack: \($0)") }
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

        // Calculate confirmations from block height
        let confirmations: Int
        if info.isPending || info.blockHeight == 0 {
            confirmations = 0
        } else if let kit = kit {
            let currentHeight = kit.lastBlockInfo
            if currentHeight > info.blockHeight {
                confirmations = Int(currentHeight - info.blockHeight)
            } else {
                confirmations = 10 // Assume confirmed if we can't calculate
            }
        } else {
            confirmations = 10 // Default to confirmed if kit unavailable
        }

        // Determine status based on isPending from MoneroKit (this is accurate!)
        let status: MoneroTransaction.TransactionStatus
        if info.isFailed {
            status = .failed
        } else if info.isPending {
            status = .pending
        } else {
            status = .confirmed
        }

        return MoneroTransaction(
            id: info.hash,
            type: info.type == .incoming ? .incoming : .outgoing,
            amount: amount,
            fee: fee,
            address: info.recipientAddress ?? "",
            timestamp: Date(timeIntervalSince1970: Double(info.timestamp)),
            confirmations: confirmations,
            status: status,
            memo: info.memo
        )
    }

    // MARK: - Send

    func estimateFee(to address: String, amount: Decimal, priority: SendPriority = .default) async throws -> Decimal {
        guard let kit = kit else {
            writeDebugLog("estimateFee: kit is nil")
            throw WalletError.notUnlocked
        }

        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        writeDebugLog("estimateFee: calling kit.estimateFee with piconero=\(piconero)")
        do {
            let fee = try kit.estimateFee(address: address, amount: .value(piconero), priority: priority)
            writeDebugLog("estimateFee: success, fee=\(fee)")
            return Decimal(fee) / coinRate
        } catch {
            writeDebugLog("estimateFee: FAILED - \(error)")
            writeDebugLog("estimateFee: error type = \(type(of: error))")
            writeDebugLog("estimateFee: localizedDescription = \(error.localizedDescription)")
            throw error
        }
    }

    private func writeDebugLog(_ message: String) {
        let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
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
        Task { @MainActor in
            self.subaddresses = subaddresses
        }
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

struct MoneroTransaction: Identifiable, Equatable, Hashable {
    let id: String
    let type: TransactionType
    let amount: Decimal
    let fee: Decimal
    let address: String
    let timestamp: Date
    let confirmations: Int
    let status: TransactionStatus
    let memo: String?

    enum TransactionType: Hashable {
        case incoming
        case outgoing
    }

    enum TransactionStatus: Hashable {
        case pending
        case confirmed
        case failed
    }

    static func == (lhs: MoneroTransaction, rhs: MoneroTransaction) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
