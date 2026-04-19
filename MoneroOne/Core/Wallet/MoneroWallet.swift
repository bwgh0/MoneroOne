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

    // MARK: - Connection Progress Tracking
    @Published var daemonHeight: UInt64 = 0
    @Published var walletHeight: UInt64 = 0
    /// Actual restore height as decoded by the C++ library (e.g. Polyseed birthday)
    @Published var actualRestoreHeight: UInt64?

    /// Primary address (index 0) - from storage (pre-computed)
    var primaryAddress: String {
        kit?.primaryAddress ?? ""
    }

    /// The actual refresh-from-block-height as set by the C++ wallet.
    /// For Polyseed, this is the decoded birthday height.
    var refreshFromBlockHeight: UInt64 {
        kit?.refreshFromBlockHeight ?? 0
    }

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
    ///   - seed: Seed words (16 for polyseed, 24 for BIP39, 25 for legacy)
    ///   - restoreHeight: Block height to restore from (0 for full sync)
    ///   - node: Optional custom node
    ///   - resetSuffix: Optional suffix to force new walletId (used for reset sync)
    ///   - networkType: Mainnet or testnet
    func create(seed: [String], restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, resetSuffix: String? = nil, networkType: MoneroKit.NetworkType = .mainnet) async throws {
        let walletNode = node ?? defaultNode(for: networkType)
        var walletId = Self.stableWalletId(for: seed)

        // Append reset suffix and network to force new wallet identity
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        if let suffix = resetSuffix {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + suffix + networkSuffix)
        } else if networkType == .testnet {
            walletId = Self.stableWalletId(for: seed.joined(separator: " ") + networkSuffix)
        }

        // Detect seed type and create appropriate credentials
        // 16 words = polyseed, 24 words = bip39, 25 words = legacy
        let credentials: MoneroKit.MoneroWallet
        switch seed.count {
        case 16:
            credentials = MoneroKit.MoneroWallet.polyseed(seed: seed, passphrase: "")
        case 25:
            credentials = MoneroKit.MoneroWallet.legacy(seed: seed, passphrase: "")
        default:
            credentials = MoneroKit.MoneroWallet.bip39(seed: seed, passphrase: "")
        }

        // Heavy Kit init (SQLite + C++ + crypto) off main thread
        let reachability = reachabilityManager
        let (newKit, initialBalance, initialAddress, initialState, initialSubaddrs) = try await Task.detached {
            let kit = try MoneroKit.Kit(
                wallet: credentials,
                account: 0,
                restoreHeight: restoreHeight,
                walletId: walletId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil
            )
            // Pre-fetch initial state off main to avoid blocking when setupKit runs
            let balance = kit.balanceInfo
            let address = kit.receiveAddress
            let state = kit.walletState
            let subaddrs = kit.usedAddresses
            return (kit, balance, address, state, subaddrs)
        }.value

        kit = newKit
        setupKit(initialBalance: initialBalance, initialAddress: initialAddress, initialState: initialState, initialSubaddrs: initialSubaddrs)
    }

    /// Create watch-only wallet
    func createWatchOnly(address: String, viewKey: String, restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, networkType: MoneroKit.NetworkType = .mainnet) async throws {
        let walletNode = node ?? defaultNode(for: networkType)
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let walletId = Self.stableWalletId(for: address + viewKey + networkSuffix)

        // Heavy Kit init (SQLite + C++ + crypto) off main thread
        let reachability = reachabilityManager
        let (newKit, initialBalance, initialAddress, initialState, initialSubaddrs) = try await Task.detached {
            let kit = try MoneroKit.Kit(
                wallet: .watch(address: address, viewKey: viewKey),
                account: 0,
                restoreHeight: restoreHeight,
                walletId: walletId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil
            )
            return (kit, kit.balanceInfo, kit.receiveAddress, kit.walletState, kit.usedAddresses)
        }.value

        kit = newKit
        setupKit(initialBalance: initialBalance, initialAddress: initialAddress, initialState: initialState, initialSubaddrs: initialSubaddrs)
    }

    private func defaultNode(for networkType: MoneroKit.NetworkType = .mainnet) -> MoneroKit.Node {
        let isTestnet = networkType == .testnet
        let urlKey = isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
        let defaultURL = isTestnet
            ? (Self.testnetNodes.first?.url ?? "http://testnet.xmr-tw.org:28081")
            : "https://node.monero.one:443"
        let savedURL = UserDefaults.standard.string(forKey: urlKey) ?? defaultURL
        guard let url = URL(string: savedURL) ?? URL(string: defaultURL) else {
            return MoneroKit.Node(url: URL(string: "https://node.monero.one:443")!, isTrusted: false)
        }

        let creds = NodeCredentialStore.load(isTestnet: isTestnet)
        let login = creds.login
        let password = creds.password
        let proxy = UserDefaults.standard.string(forKey: "proxyAddress")

        return MoneroKit.Node(
            url: url,
            isTrusted: false,
            login: login,
            password: password,
            proxy: proxy
        )
    }

    #if DEBUG
    /// Available public testnet nodes (port 28081/28089)
    /// Note: Testnet nodes are often unreliable. MoneroKit doesn't support stagenet.
    static let testnetNodes: [(name: String, url: String)] = [
        ("Monero Project", "http://testnet.xmr-tw.org:28081"),
        ("MoneroDevs", "http://node.monerodevs.org:28089"),
    ]
    #else
    static let testnetNodes: [(name: String, url: String)] = []
    #endif

    private func setupKit(initialBalance: MoneroKit.BalanceInfo, initialAddress: String, initialState: MoneroKit.WalletState, initialSubaddrs: [MoneroKit.SubAddress]) {
        guard let kit = kit else { return }

        // Set delegate
        kit.delegate = self

        // Apply pre-fetched initial values (no C++ calls on main)
        updateBalance(initialBalance)
        address = initialAddress
        updateSyncState(initialState)
        subaddresses = initialSubaddrs

        // Start syncing
        kit.start()
    }

    // MARK: - Lifecycle

    deinit {
        #if DEBUG
        print("[MoneroWallet] deinit called")
        #endif
    }

    func start() {
        kit?.start()
    }

    func stop() {
        #if DEBUG
        print("[MoneroWallet] stop() called")
        #endif
        kit?.stop()
    }

    /// Awaits actual C++ teardown completion. Use before starting another
    /// wallet (so wallet2's process-global state isn't shared between two
    /// live wallets) or before iOS suspends the process in the background
    /// (so the refresh thread isn't frozen mid-HTTP-op).
    func stopAsync() async {
        #if DEBUG
        print("[MoneroWallet] stopAsync() called")
        #endif
        await kit?.stopAsync()
    }

    func refresh() {
        // Kit.refresh() now dispatches its wallet2 work onto the kit's own
        // lifecycle queue, so callers no longer need to wrap in Task.detached
        // to stay off main. Wrapping again would just shuffle threads —
        // wallet2 still ends up serialized on lifecycleQueue.
        kit?.refresh()
    }

    /// Restart sync to check for new blocks
    func startSync() {
        kit?.startSync()
    }

    /// Pause wallet2's refresh thread without tearing down the wallet.
    /// Call this when the app goes to background so iOS doesn't suspend the
    /// process mid-HTTP-fetch, which leaves wallet2's asio state torn and
    /// crashes when the app resumes. Cheaper than `stopAsync` — preserves
    /// pointers/callbacks so `startSync()` resumes from where we left off.
    /// Fire-and-forget; for "must finish before iOS suspends" use
    /// `pauseSyncAsync`.
    func pauseSync() {
        kit?.pauseSync()
    }

    /// Async variant of `pauseSync` that resolves only after wallet2's
    /// refresh thread has actually been signalled to stop. Use under a
    /// `beginBackgroundTask` assertion so iOS doesn't suspend the process
    /// before pause completes.
    func pauseSyncAsync() async {
        await kit?.pauseSyncAsync()
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
            #if DEBUG
            NSLog("[MoneroWallet] notSynced raw error: %@", String(describing: error))
            #endif
            syncState = .error(friendlyErrorMessage(for: error))
        case .idle:
            syncState = .idle
        }

        // Update block heights for connection progress tracking
        if let heights = kit?.blockHeights {
            walletHeight = heights.walletHeight
            daemonHeight = heights.daemonHeight
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let errorString = String(describing: error)
        #if DEBUG
        NSLog("[MoneroWallet] friendlyErrorMessage input: '%@' containsTimeout=%d", errorString, errorString.lowercased().contains("timeout") ? 1 : 0)
        #endif

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

        if errorString.lowercased().contains("timeout") || errorString.lowercased().contains("timed out") {
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
        let rate = coinRate

        Task.detached {
            let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: 100)
            let mapped = txInfos.map { MoneroWallet.mapTransaction($0, coinRate: rate, kit: kit) }
            await MainActor.run { [weak self] in
                self?.transactions = mapped
            }
        }
    }

    nonisolated private static func mapTransaction(_ info: MoneroKit.TransactionInfo, coinRate: Decimal, kit: MoneroKit.Kit) -> MoneroTransaction {
        let amount = Decimal(info.amount) / coinRate
        let fee = Decimal(info.fee) / coinRate

        // Calculate confirmations from block height
        let confirmations: Int?
        if info.isPending || info.blockHeight == 0 {
            confirmations = 0
        } else {
            let currentHeight = kit.blockHeights?.daemonHeight ?? kit.lastBlockInfo
            if currentHeight > info.blockHeight {
                confirmations = Int(currentHeight - info.blockHeight)
            } else {
                confirmations = nil
            }
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

        // Guard against calling C++ estimateTransactionFee before wallet has a daemon connection —
        // wallet2 calls abort() instead of returning an error when not connected.
        switch syncState {
        case .synced, .syncing:
            break // wallet has a connection, safe to call C++
        default:
            writeDebugLog("estimateFee: wallet not synced (state: \(syncState)), refusing to call C++")
            throw MoneroCoreError.transactionEstimationFailed("Wallet is not synced. Please wait for sync to complete.")
        }

        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        writeDebugLog("estimateFee: calling kit.estimateFee with piconero=\(piconero)")
        do {
            let fee = try await Task.detached {
                try kit.estimateFee(address: address, amount: .value(piconero), priority: priority)
            }.value
            writeDebugLog("estimateFee: success, fee=\(fee)")
            return Decimal(fee) / coinRate
        } catch {
            writeDebugLog("estimateFee: FAILED - \(error)")
            writeDebugLog("estimateFee: error type = \(type(of: error))")
            writeDebugLog("estimateFee: localizedDescription = \(error.localizedDescription)")
            throw error
        }
    }

    #if DEBUG
    private func writeDebugLog(_ message: String) {
        guard let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let logFile = documentDir.appendingPathComponent("debug.log")
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
    #else
    private func writeDebugLog(_ message: String) {
        // No-op in release builds
    }
    #endif

    func send(to address: String, amount: Decimal, priority: SendPriority = .default, memo: String? = nil) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }

        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        writeDebugLog("send: starting send to \(address.prefix(16))..., piconero=\(piconero)")

        try await Task.detached {
            try kit.send(to: address, amount: .value(piconero), priority: priority, memo: memo)
        }.value
        writeDebugLog("send: kit.send completed, fetching transactions")

        let txId = await Task.detached { () -> String in
            let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: 1)
            return txInfos.first?.hash ?? ""
        }.value
        writeDebugLog("send: got txId=\(txId)")

        fetchTransactions()
        return txId
    }

    func sendAll(to address: String, priority: SendPriority = .default, memo: String? = nil) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }

        writeDebugLog("sendAll: starting sweep to \(address.prefix(16))...")

        try await Task.detached {
            try kit.send(to: address, amount: .all, priority: priority, memo: memo)
        }.value
        writeDebugLog("sendAll: kit.send completed, fetching transactions")

        let txId = await Task.detached { () -> String in
            let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: 1)
            return txInfos.first?.hash ?? ""
        }.value
        writeDebugLog("sendAll: got txId=\(txId)")

        fetchTransactions()
        return txId
    }

    // MARK: - Seed Export

    /// Returns the legacy 25-word seed from the running wallet.
    func getLegacySeed() -> [String]? {
        guard let seed = kit?.getLegacySeed(), !seed.isEmpty else { return nil }
        return seed.split(separator: " ").map(String.init)
    }

    /// Returns the polyseed (16 words) if wallet was created with one.
    func getPolyseed() -> [String]? {
        guard let seed = kit?.getPolyseed(), !seed.isEmpty else { return nil }
        return seed.split(separator: " ").map(String.init)
    }

    // MARK: - Subaddresses

    /// Create a new subaddress for receiving payments
    /// - Returns: The newly created SubAddress, or nil if creation failed
    func createSubaddress() -> MoneroKit.SubAddress? {
        guard let kit = kit else { return nil }
        return kit.createSubaddress()
    }

    /// Update label on an existing subaddress, persisted via wallet2 cache.
    @discardableResult
    func setSubaddressLabel(index: Int, label: String) -> Bool {
        guard let kit = kit else { return false }
        return kit.setSubaddressLabel(index: index, label: label)
    }

    /// The wallet's private view key, or nil if not yet loaded.
    var secretViewKey: String? { kit?.secretViewKey }

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
    static func stableWalletId(for seed: [String]) -> String {
        stableWalletId(for: seed.joined(separator: " "))
    }

    /// Generate a stable wallet ID from any string (seed phrase or address+viewKey)
    static func stableWalletId(for identifier: String) -> String {
        let data = Data(identifier.utf8)
        let hash = SHA256.hash(data: data)
        // Use first 16 bytes as a UUID-like identifier
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MoneroKitDelegate

extension MoneroWallet: MoneroKitDelegate {
    nonisolated func subAddressesUpdated(subaddresses: [MoneroKit.SubAddress]) {
        #if DEBUG
        NSLog("[MoneroWallet] subAddressesUpdated: count=%d", subaddresses.count)
        #endif
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

    nonisolated func restoreHeightUpdated(height: UInt64) {
        #if DEBUG
        NSLog("[MoneroWallet] restoreHeightUpdated: %llu", height)
        #endif
        Task { @MainActor in
            self.actualRestoreHeight = height
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
    let confirmations: Int?
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
