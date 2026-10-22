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

    /// Primary address (index 0). Reads from MoneroKit's GRDB storage
    /// when populated (the normal case after `Kit.start()` runs its
    /// _start phase 1), and falls back to wallet2's live runtime if
    /// storage is empty. The fallback matters for sidecar wallets
    /// opened via `prepareOnly()`, which deliberately skips the
    /// storage-populate step so wallet2 never enters refresh mode.
    var primaryAddress: String {
        let stored = kit?.primaryAddress ?? ""
        if !stored.isEmpty { return stored }
        return kit?.runtimePrimaryAddress ?? ""
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
    /// The node the kit connects to, with the login and the proxy it uses.
    private var node: MoneroKit.Node?
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
    ///   - cacheIdOverride: Payment-link envelopes only: a cache id outside
    ///     the 32-hex namespace, so the launch sweep never deletes it.
    func create(seed: [String], restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, resetSuffix: String? = nil, networkType: MoneroKit.NetworkType = .mainnet, cacheIdOverride: String? = nil) async throws {
        let walletNode = node ?? defaultNode(for: networkType)
        let walletId = cacheIdOverride ?? Self.walletCacheId(
            seedPhrase: seed.joined(separator: " "),
            resetSuffix: resetSuffix,
            networkType: networkType
        )

        let credentials = Self.kitCredentials(for: seed)

        // Heavy Kit init (SQLite + C++ + crypto) off main thread
        let reachability = reachabilityManager
        let rate = coinRate
        let (newKit, initialBalance, initialAddress, initialState, initialSubaddrs, initialTransactions) = try await Task.detached {
            let kit = try MoneroKit.Kit(
                wallet: credentials,
                account: 0,
                restoreHeight: restoreHeight,
                walletId: walletId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil,
                // Wallet2's epee logger writes to a process-global std::ofstream
                // from multiple internal boost threads without a mutex. Two
                // workers logging concurrently corrupt the streambuf and
                // segfault in _platform_memmove. Silence the logger so the
                // race has nothing to race on. Level 0 = fatal-only.
                moneroCoreLogLevel: 0
            )
            // Pre-fetch initial state off main to avoid blocking when setupKit runs
            let balance = kit.balanceInfo
            let address = kit.receiveAddress
            let state = kit.walletState
            let subaddrs = kit.usedAddresses
            let transactions = MoneroWallet.storedTransactions(of: kit, coinRate: rate)
            return (kit, balance, address, state, subaddrs, transactions)
        }.value

        self.node = walletNode
        kit = newKit
        setupKit(initialBalance: initialBalance, initialAddress: initialAddress, initialState: initialState, initialSubaddrs: initialSubaddrs, initialTransactions: initialTransactions)
    }

    /// Open (or create on first connect) a wallet bound to a hardware
    /// device. The on-disk cache is keyed by `walletId` rather than a
    /// hash of credentials so the caller can pin the sidecar to a
    /// stable identifier (typically `WalletInfo.deviceWalletId`, derived
    /// from the THP device id). The Trezor bridge HTTP server must be
    /// running and the device must be reachable through it before this
    /// call — wallet2 contacts the device during `restore_from_device`.
    func createFromDevice(
        deviceName: String,
        walletId: String,
        restoreHeight: UInt64 = 0,
        node: MoneroKit.Node? = nil,
        networkType: MoneroKit.NetworkType = .mainnet
    ) async throws {
        let walletNode = node ?? defaultNode(for: networkType)

        // Heavy Kit init off main thread — wallet2 contacts the device
        // during restore_from_device which can take seconds.
        let reachability = reachabilityManager
        let rate = coinRate
        let (newKit, initialBalance, initialAddress, initialState, initialSubaddrs, initialTransactions) = try await Task.detached {
            let kit = try MoneroKit.Kit(
                wallet: .trezor(deviceName: deviceName),
                account: 0,
                restoreHeight: restoreHeight,
                walletId: walletId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil,
                moneroCoreLogLevel: 0
            )
            return (kit, kit.balanceInfo, kit.receiveAddress, kit.walletState, kit.usedAddresses,
                    MoneroWallet.storedTransactions(of: kit, coinRate: rate))
        }.value

        self.node = walletNode
        kit = newKit
        setupKit(initialBalance: initialBalance, initialAddress: initialAddress, initialState: initialState, initialSubaddrs: initialSubaddrs, initialTransactions: initialTransactions)
    }

    /// Create watch-only wallet
    func createWatchOnly(address: String, viewKey: String, restoreHeight: UInt64 = 0, node: MoneroKit.Node? = nil, networkType: MoneroKit.NetworkType = .mainnet) async throws {
        let walletNode = node ?? defaultNode(for: networkType)
        let walletId = Self.viewOnlyCacheId(address: address, viewKey: viewKey, networkType: networkType)

        // Heavy Kit init (SQLite + C++ + crypto) off main thread
        let reachability = reachabilityManager
        let rate = coinRate
        let (newKit, initialBalance, initialAddress, initialState, initialSubaddrs, initialTransactions) = try await Task.detached {
            let kit = try MoneroKit.Kit(
                wallet: .watch(address: address, viewKey: viewKey),
                account: 0,
                restoreHeight: restoreHeight,
                walletId: walletId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil,
                // See `create` — silence wallet2's unlocked logger writes.
                moneroCoreLogLevel: 0
            )
            return (kit, kit.balanceInfo, kit.receiveAddress, kit.walletState, kit.usedAddresses,
                    MoneroWallet.storedTransactions(of: kit, coinRate: rate))
        }.value

        self.node = walletNode
        kit = newKit
        setupKit(initialBalance: initialBalance, initialAddress: initialAddress, initialState: initialState, initialSubaddrs: initialSubaddrs, initialTransactions: initialTransactions)
    }

    /// Detect seed type and create appropriate credentials.
    /// 16 words = polyseed, 24 words = bip39, 25 words = legacy.
    /// The primary address `seed` opens to. A throwaway wallet2 opens in a
    /// temporary cache directory, which is deleted again; it never connects
    /// to a node and never refreshes. The library's static address helper
    /// is a stub, so this is the only way to read the address before the
    /// wallet is saved. wallet2 runs one wallet at a time: stop the running
    /// wallet first.
    func probePrimaryAddress(seed: [String], networkType: MoneroKit.NetworkType) async throws -> String {
        // 32 hex characters, so the launch sweep removes the directory if
        // the app dies before the cleanup below.
        let probeId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defer {
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("MoneroKit").appendingPathComponent(probeId))
            }
        }
        let credentials = Self.kitCredentials(for: seed)
        let walletNode = defaultNode(for: networkType)
        let reachability = reachabilityManager
        let probe = try await Task.detached {
            try MoneroKit.Kit(
                wallet: credentials,
                account: 0,
                restoreHeight: 0,
                walletId: probeId,
                node: walletNode,
                networkType: networkType,
                reachabilityManager: reachability,
                logger: nil,
                // See `create` — silence wallet2's unlocked logger writes.
                moneroCoreLogLevel: 0
            )
        }.value
        await probe.prepareOnly()
        let address = probe.runtimePrimaryAddress
        await probe.stopAsync()
        return address
    }

    private func defaultNode(for networkType: MoneroKit.NetworkType = .mainnet) -> MoneroKit.Node {
        let isTestnet = networkType == .testnet
        let urlKey = isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL"
        let defaultURL = isTestnet
            ? (Self.testnetNodes.first?.url ?? "http://testnet.xmr-tw.org:28081")
            : "https://node.monero.one:443"
        let savedURL = UserDefaults.standard.string(forKey: urlKey) ?? defaultURL
        // The Tor setting goes on every node, the fallback too.
        let proxy = UserDefaults.standard.string(forKey: TorNetwork.proxyKey)
        guard let url = URL(string: savedURL) ?? URL(string: defaultURL) else {
            return MoneroKit.Node(url: URL(string: "https://node.monero.one:443")!, isTrusted: false, proxy: proxy)
        }

        let creds = NodeCredentialStore.load(isTestnet: isTestnet)
        let login = creds.login
        let password = creds.password

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

    private func setupKit(initialBalance: MoneroKit.BalanceInfo, initialAddress: String, initialState: MoneroKit.WalletState, initialSubaddrs: [MoneroKit.SubAddress], initialTransactions: [MoneroTransaction]) {
        guard let kit = kit else { return }

        // Set delegate
        kit.delegate = self

        // Apply pre-fetched initial values (no C++ calls on main)
        updateBalance(initialBalance)
        address = initialAddress
        updateSyncState(initialState)
        subaddresses = initialSubaddrs
        // The stored history shows with the stored balance. The kit sends
        // its list only after a refresh, and a slow or stuck node can hold
        // that off for minutes: the history said "no transactions" while
        // the balance showed.
        transactions = initialTransactions

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
            // The friendly message discards the wallet2 error string, which
            // is the only thing that identifies a sync regression in the
            // field. Keep the raw error in the pullable trezor log — it's
            // the primary diagnostic for hardware-session sync failures.
            TrezorLog.log("[MoneroWallet] notSynced raw error: %@ | wallet2: %@",
                          String(describing: error), latestErrorString)
            let message = friendlyErrorMessage(for: error)
            syncState = .error(message)
            checkNodeLogin(after: message)
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
                return String(localized: "Unable to connect to node. Please try a different node in Settings.")
            } else if errorString.contains("error 2") {
                return String(localized: "Node returned invalid response. Try another node.")
            } else if errorString.contains("error 3") {
                return String(localized: "Connection timeout. Check your internet connection.")
            }
        }

        if errorString.lowercased().contains("timeout") || errorString.lowercased().contains("timed out") {
            return String(localized: "Connection timed out. Try again or switch nodes.")
        }

        if errorString.lowercased().contains("network") || errorString.lowercased().contains("internet") {
            return String(localized: "Network error. Check your connection.")
        }

        if errorString.lowercased().contains("refused") || errorString.lowercased().contains("unreachable") {
            return String(localized: "Node unavailable. Try a different node.")
        }

        // Fallback to a cleaner message
        return String(localized: "Sync failed. Tap Retry or try a different node.")
    }

    // MARK: - Node Login

    /// A node with the login and the proxy the kit uses for it.
    private struct LoginCheckNode: Equatable {
        let url: String
        let credentials: NodeCredentials
        let proxy: String

        init(_ node: MoneroKit.Node) {
            url = node.url.absoluteString
            credentials = NodeCredentials(login: node.login, password: node.password)
            proxy = node.proxy ?? ""
        }
    }

    /// The login check in flight. Every wallet on the same node and login
    /// shares it, so a burst of sync errors runs one check.
    private static var runningLoginCheck: (node: LoginCheckNode, task: Task<NodeLoginCheck, Never>)?

    /// A node that turns the login down fails a sync like a node that does
    /// not answer: wallet2 gets no height and the kit reports a timeout. So
    /// after a sync error on a custom node, this asks the node. When it turns
    /// the login down, the error says so, unless another state came first.
    private func checkNodeLogin(after message: String) {
        guard let node else { return }
        let checked = LoginCheckNode(node)
        // The built-in nodes are public and take no login.
        let builtIn = NodeManager.defaultNodes + NodeManager.torNodes + NodeManager.defaultTestnetNodes
        guard !builtIn.contains(where: { $0.url == checked.url }) else { return }

        let check: Task<NodeLoginCheck, Never>
        if let running = Self.runningLoginCheck, running.node == checked {
            check = running.task
        } else {
            check = Task {
                await NodeLoginProbe.check(url: checked.url, credentials: checked.credentials, proxy: checked.proxy)
            }
            Self.runningLoginCheck = (checked, check)
        }
        Task { [weak self] in
            let result = await check.value
            if Self.runningLoginCheck?.task == check {
                Self.runningLoginCheck = nil
            }
            // The answer is about the checked node. If the kit moved to
            // another node, login or proxy during the check, it is stale.
            guard result == .rejected, let self, self.syncState == .error(message),
                  self.node.map(LoginCheckNode.init) == checked else { return }
            self.syncState = .error(String(localized: "Node login failed. Check the username and password."))
        }
    }

    // MARK: - Transactions

    /// How many of the newest transactions `transactions` holds.
    nonisolated static let recentTransactionLimit = 100

    /// The newest transactions in the kit's database, as the last run of
    /// this wallet stored them. Reads no wallet2 state, so it works before
    /// `kit.start()`. The database is per wallet, so the rows are always
    /// this wallet's own.
    nonisolated static func storedTransactions(of kit: MoneroKit.Kit, coinRate: Decimal) -> [MoneroTransaction] {
        kit.transactions(fromHash: nil, descending: true, type: nil, limit: recentTransactionLimit)
            .map { mapTransaction($0, coinRate: coinRate, kit: kit) }
    }

    func fetchTransactions() {
        guard let kit = kit else { return }
        let rate = coinRate

        Task.detached {
            let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: MoneroWallet.recentTransactionLimit)
            let mapped = txInfos.map { MoneroWallet.mapTransaction($0, coinRate: rate, kit: kit) }
            await MainActor.run { [weak self] in
                self?.transactions = mapped
            }
        }
    }

    /// Synchronous read of wallet2's transaction list, bypassing the
    /// fire-and-forget `Task.detached` + main-hop in `fetchTransactions`.
    /// Used by the hardware-session snapshot path where we need to
    /// capture the just-broadcast tx without racing the publisher.
    /// Also updates the `@Published transactions` mirror so any
    /// observers see the same list.
    func fetchTransactionsBlocking() async -> [MoneroTransaction] {
        guard let kit = kit else { return [] }
        let rate = coinRate
        let mapped = await Task.detached { () -> [MoneroTransaction] in
            let txInfos = kit.transactions(fromHash: nil, descending: true, type: nil, limit: MoneroWallet.recentTransactionLimit)
            return txInfos.map { MoneroWallet.mapTransaction($0, coinRate: rate, kit: kit) }
        }.value
        self.transactions = mapped
        return mapped
    }

    /// Every transaction of this account, newest first, with no count
    /// limit. `transactions` keeps only the newest 100; the portfolio
    /// chart needs all of them to know the balance held on older dates.
    /// Leaves `transactions` alone.
    func fetchAllTransactions() async -> [MoneroTransaction] {
        guard let kit = kit else { return transactions }
        let rate = coinRate
        return await Task.detached { () -> [MoneroTransaction] in
            kit.transactions(fromHash: nil, descending: true, type: nil, limit: nil)
                .map { MoneroWallet.mapTransaction($0, coinRate: rate, kit: kit) }
        }.value
    }

    nonisolated private static func mapTransaction(_ info: MoneroKit.TransactionInfo, coinRate: Decimal, kit: MoneroKit.Kit) -> MoneroTransaction {
        let amount = Decimal(info.amount) / coinRate
        let fee = Decimal(info.fee) / coinRate
        let type: MoneroTransaction.TransactionType = info.type == .incoming ? .incoming : .outgoing

        // wallet2 only knows destinations for transactions it built on
        // this device; a wallet restored from seed gets none, and the
        // empty list is the honest answer in that case.
        let destinations = info.destinations.map {
            MoneroTransactionDestination(address: $0.address, amount: Decimal($0.amount) / coinRate)
        }

        // `address` keeps one meaning per direction: the subaddress we
        // received on for incoming, the first destination for outgoing.
        let address: String
        let subaddressIndex: Int?
        switch type {
        case .incoming:
            address = info.recipientAddress ?? ""
            subaddressIndex = info.subaddressIndices.first
        case .outgoing:
            address = destinations.first?.address ?? ""
            subaddressIndex = nil
        }

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
            type: type,
            amount: amount,
            fee: fee,
            address: address,
            timestamp: Date(timeIntervalSince1970: Double(info.timestamp)),
            confirmations: confirmations,
            status: status,
            memo: info.memo,
            blockHeight: info.blockHeight == 0 ? nil : info.blockHeight,
            destinations: destinations,
            subaddressIndex: subaddressIndex
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
            throw MoneroCoreError.transactionEstimationFailed(String(localized: "Wallet is not synced. Please wait for sync to complete."))
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

    /// Runs after signing and before the broadcast, with the final txids.
    /// When it throws, nothing is broadcast and the send throws
    /// `BroadcastCancelled`.
    typealias BeforeBroadcast = @MainActor (PreparedTransaction) async throws -> Void

    /// The `BeforeBroadcast` step threw: the signed transaction was dropped
    /// and nothing reached the network.
    struct BroadcastCancelled: LocalizedError {
        let underlying: Error
        var errorDescription: String? { (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription }
    }

    /// Returns the txid of the broadcast transaction.
    func send(to address: String, amount: Decimal, priority: SendPriority = .default, memo: String? = nil,
              beforeBroadcast: BeforeBroadcast? = nil) async throws -> String {
        let piconero = Int((amount * coinRate) as NSDecimalNumber)
        writeDebugLog("send: starting send to \(address.prefix(16))..., piconero=\(piconero)")
        return try await send(to: address, amount: .value(piconero), priority: priority, memo: memo, beforeBroadcast: beforeBroadcast)
    }

    /// Sweeps the whole unlocked balance. Returns the txid of the broadcast
    /// transaction.
    func sendAll(to address: String, priority: SendPriority = .default, memo: String? = nil,
                 beforeBroadcast: BeforeBroadcast? = nil) async throws -> String {
        writeDebugLog("sendAll: starting sweep to \(address.prefix(16))...")
        return try await send(to: address, amount: .all, priority: priority, memo: memo, beforeBroadcast: beforeBroadcast)
    }

    /// Signs a transfer of `amount` XMR to `address` (a sweep of the
    /// unlocked balance when `amount` is nil) and keeps it, not sent: its
    /// fee is the one it pays for the inputs it really spends (wallet2's
    /// estimate counts one). `send(_:beforeBroadcast:)` broadcasts this
    /// same transaction.
    func prepareSend(to address: String, amount: Decimal?, priority: SendPriority = .default, memo: String? = nil) async throws -> PreparedTransaction {
        guard let kit = kit else { throw WalletError.notUnlocked }

        // Same gate as estimateFee: building needs a daemon connection.
        switch syncState {
        case .synced, .syncing:
            break
        default:
            writeDebugLog("prepareSend: wallet not synced (state: \(syncState))")
            throw MoneroCoreError.transactionEstimationFailed(String(localized: "Wallet is not synced. Please wait for sync to complete."))
        }

        let sendAmount: SendAmount
        if let amount {
            // wallet2 reads an amount of 0 as a sweep of the whole balance.
            let piconero = Int((amount * coinRate) as NSDecimalNumber)
            guard piconero > 0 else {
                throw MoneroCoreError.transactionSendFailed(String(localized: "Invalid amount"))
            }
            sendAmount = .value(piconero)
        } else {
            sendAmount = .all
        }
        let prepared = try await Task.detached {
            try kit.prepareSend(to: address, amount: sendAmount, priority: priority, memo: memo)
        }.value
        writeDebugLog("prepareSend: fee=\(prepared.fee), txs=\(prepared.txids.count)")
        return prepared
    }

    /// The transaction from `prepareSend` can still go out: the wallet it
    /// was signed in is still open, and it was not sent.
    func isPrepared(_ prepared: PreparedTransaction) async -> Bool {
        guard let kit = kit else { return false }
        return await Task.detached { kit.isPrepared(prepared) }.value
    }

    /// Runs `beforeBroadcast`, then broadcasts `prepared` (from
    /// `prepareSend`). Returns its txid. Throws
    /// `MoneroCoreError.walletNotInitialized`, with nothing sent, when the
    /// wallet it was signed in closed since.
    func send(_ prepared: PreparedTransaction, beforeBroadcast: BeforeBroadcast? = nil) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }
        return try await broadcast(prepared, kit: kit, beforeBroadcast: beforeBroadcast)
    }

    /// Signs, runs `beforeBroadcast`, then broadcasts. The txid comes from
    /// the signed transaction, never from the newest history row: the
    /// history can lag the broadcast.
    private func send(to address: String, amount: SendAmount, priority: SendPriority, memo: String?,
                      beforeBroadcast: BeforeBroadcast?) async throws -> String {
        guard let kit = kit else { throw WalletError.notUnlocked }

        let prepared = try await Task.detached {
            try kit.prepareSend(to: address, amount: amount, priority: priority, memo: memo)
        }.value
        return try await broadcast(prepared, kit: kit, beforeBroadcast: beforeBroadcast)
    }

    private func broadcast(_ prepared: PreparedTransaction, kit: MoneroKit.Kit,
                           beforeBroadcast: BeforeBroadcast?) async throws -> String {
        if let beforeBroadcast {
            do {
                try await beforeBroadcast(prepared)
            } catch {
                writeDebugLog("send: not broadcast, the step before it failed")
                throw BroadcastCancelled(underlying: error)
            }
        }
        try await Task.detached {
            try kit.commit(prepared)
        }.value
        let txId = prepared.txids.first ?? ""
        writeDebugLog("send: committed txId=\(txId)")

        fetchTransactions()
        return txId
    }

    /// XMR to piconero, as `send(to:amount:)` converts it.
    nonisolated static func piconero(_ amount: Decimal) -> Int {
        Int((amount * 1_000_000_000_000) as NSDecimalNumber)
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

    /// Per-transaction secret key, shared alongside txid + destination
    /// address to let the recipient prove the payment.
    func getTxKey(txId: String) -> String? {
        kit?.getTxKey(txId: txId)
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

    // MARK: - Hardware-wallet primitives
    //
    // The dual-cache architecture opens this MoneroWallet during a
    // reconnect session against the FULL TREZOR-bound cache. After
    // refresh has populated m_transfers, the session driver runs
    // `coldKeyImageSync` which asks the device for signed key images
    // and imports them into the FULL cache.

    @discardableResult
    func reconnectDevice() async -> Bool {
        await kit?.reconnectDevice() ?? false
    }

    @discardableResult
    func coldKeyImageSync() async -> Bool {
        await kit?.coldKeyImageSync() ?? false
    }

    var deviceType: MoneroKit.Kit.DeviceType {
        kit?.deviceType ?? .software
    }

    /// Latest wallet2 error string, for diagnostics after a wallet2 call
    /// returns false.
    var latestErrorString: String {
        kit?.latestStatus.message ?? ""
    }

    // MARK: - Validation

    static func isValidAddress(_ address: String, networkType: MoneroKit.NetworkType = .mainnet) -> Bool {
        MoneroKit.Kit.isValid(address: address, networkType: networkType)
    }

    /// True when `viewKey` is the private view key of `address`: wallet2's
    /// `keyValid` derives the public view key and compares it with the one
    /// in the address. No wallet is opened.
    nonisolated static func isValidViewKey(_ viewKey: String, for address: String, networkType: MoneroKit.NetworkType = .mainnet) -> Bool {
        MoneroKit.Kit.isValid(viewKey: viewKey, address: address, isViewKey: true, networkType: networkType)
    }

    // MARK: - Restore Height

    static func restoreHeight(for date: Date) -> UInt64 {
        UInt64(MoneroKit.RestoreHeight.getHeight(date: date))
    }

    // MARK: - Wallet ID

    /// Generate a stable wallet ID from seed words - ensures sync data persists across app restarts
    nonisolated static func stableWalletId(for seed: [String]) -> String {
        stableWalletId(for: seed.joined(separator: " "))
    }

    /// The credentials the kit restores `seed` from: 16 words are Polyseed,
    /// 25 are legacy, anything else is BIP39.
    ///
    /// Legacy words go to the kit in their exact list form. wallet2
    /// lower-cases with `towlower` in the C locale, which maps ASCII only,
    /// so a stored "ästhetik" (the old free-text restore lower-cased input)
    /// never meets the German list word "Ästhetik". The stored words stay as
    /// they are: `walletCacheId` hashes them, so map only here.
    nonisolated static func kitCredentials(for seed: [String]) -> MoneroKit.MoneroWallet {
        switch seed.count {
        case 16:
            return .polyseed(seed: seed, passphrase: "")
        case 25:
            if case .valid(let phrase) = SeedPhraseValidator.validate(seed, format: .legacy) {
                return .legacy(seed: phrase.words, passphrase: "")
            }
            return .legacy(seed: seed, passphrase: "")
        default:
            return .bip39(seed: seed, passphrase: "")
        }
    }

    /// The on-disk wallet2 cache id for a seeded wallet. This is the single
    /// source of truth shared by `create()` and by WalletManager's persisted
    /// `derivedWalletId` — the launch-time orphan sweep deletes any cache dir
    /// whose name it doesn't recognize, so the two derivations diverging
    /// means the sweep destroys the live cache (full re-sync, and the tx
    /// keys stored only in that cache are gone for good).
    ///
    /// Also a compatibility surface: existing installs have caches at these
    /// exact ids. Changing the formula orphans every user's synced state.
    /// The golden-value tests in WalletCacheIdTests pin it.
    nonisolated static func walletCacheId(seedPhrase: String, resetSuffix: String?, networkType: MoneroKit.NetworkType) -> String {
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        return stableWalletId(for: seedPhrase + (resetSuffix ?? "") + networkSuffix)
    }

    /// View-only / hardware-wallet counterpart of `walletCacheId` — same
    /// lockstep and compatibility rules apply.
    nonisolated static func viewOnlyCacheId(address: String, viewKey: String, networkType: MoneroKit.NetworkType) -> String {
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        return stableWalletId(for: address + viewKey + networkSuffix)
    }

    /// Generate a stable wallet ID from any string (seed phrase or address+viewKey)
    nonisolated static func stableWalletId(for identifier: String) -> String {
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

/// One output of an outgoing transaction: the address paid and the
/// amount in XMR.
struct MoneroTransactionDestination: Equatable, Hashable, Codable {
    let address: String
    let amount: Decimal
}

struct MoneroTransaction: Identifiable, Equatable, Hashable {
    let id: String
    let type: TransactionType
    let amount: Decimal
    let fee: Decimal
    /// Incoming: the subaddress of this wallet the funds arrived on.
    /// Outgoing: the first destination address, or "" when wallet2 has
    /// no record of the destinations (see `destinations`).
    let address: String
    let timestamp: Date
    let confirmations: Int?
    let status: TransactionStatus
    let memo: String?
    /// The block height the tx was included in (0 / nil for pending).
    /// Needed to recompute confirmations on the fly for entries that
    /// were captured in a hardware-session snapshot — without it the
    /// snapshot's confirmation count is frozen at write time and the
    /// All Transactions row stays stuck at "1 confirmation" even
    /// after the chain has moved hundreds of blocks past it.
    let blockHeight: UInt64?
    /// Every destination of an outgoing transaction, in wallet2 order.
    /// Empty for incoming transactions, and for outgoing ones wallet2
    /// did not build on this device (restored from seed): destinations
    /// are not on chain, so nothing can recover them.
    let destinations: [MoneroTransactionDestination]
    /// Incoming: the minor index of the subaddress the funds arrived
    /// on. nil for outgoing transactions.
    let subaddressIndex: Int?

    init(
        id: String,
        type: TransactionType,
        amount: Decimal,
        fee: Decimal,
        address: String,
        timestamp: Date,
        confirmations: Int?,
        status: TransactionStatus,
        memo: String?,
        blockHeight: UInt64?,
        destinations: [MoneroTransactionDestination] = [],
        subaddressIndex: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.amount = amount
        self.fee = fee
        self.address = address
        self.timestamp = timestamp
        self.confirmations = confirmations
        self.status = status
        self.memo = memo
        self.blockHeight = blockHeight
        self.destinations = destinations
        self.subaddressIndex = subaddressIndex
    }

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

// MARK: - Balance History

/// One transaction's effect on the balance the app shows.
struct BalanceChange: Equatable {
    let id: String
    let type: MoneroTransaction.TransactionType
    let timestamp: Date
    /// The amount the activity list shows for the transaction.
    let amount: Decimal
    /// Signed change to the balance: +amount received, -(amount + fee) sent.
    let delta: Decimal

    /// nil when the transaction never moved the balance: a failed one,
    /// or an incoming one still in the pool when the balance does not
    /// count those yet. wallet2's balance leaves pool incoming out; the
    /// hardware display balance adds new incoming as soon as the view
    /// wallet sees it.
    init?(_ tx: MoneroTransaction, countsPendingIncoming: Bool) {
        if tx.status == .failed { return nil }
        if tx.type == .incoming, tx.status == .pending, !countsPendingIncoming { return nil }
        self.id = tx.id
        self.type = tx.type
        self.timestamp = tx.timestamp
        self.amount = tx.amount
        self.delta = tx.type == .incoming ? tx.amount : -(tx.amount + tx.fee)
    }
}

/// What it takes to know the balance held at any past moment: the
/// balance now and every change that led to it. Walking back from the
/// balance now, not forward from zero, keeps the newest point equal to
/// the balance on screen.
struct BalanceLedger: Equatable {
    /// The balance the app shows now, in XMR.
    let balance: Decimal
    /// Oldest first.
    let changes: [BalanceChange]
    /// The changes are complete from this moment on. Earlier, the
    /// balance is unknown. nil when they reach back to the wallet's
    /// first transaction.
    let knownSince: Date?

    /// The same loaded history backs both the chart and its activity list.
    /// Keep full records so an older point can still open transaction details.
    let transactions: [MoneroTransaction]

    init(balance: Decimal, changes: [BalanceChange], knownSince: Date? = nil, transactions: [MoneroTransaction] = []) {
        self.balance = balance
        self.changes = changes.sorted { $0.timestamp < $1.timestamp }
        self.knownSince = knownSince
        self.transactions = transactions.sorted { $0.timestamp > $1.timestamp }
    }

    init(balance: Decimal, transactions: [MoneroTransaction], countsPendingIncoming: Bool, knownSince: Date? = nil) {
        self.init(
            balance: balance,
            changes: transactions.compactMap { BalanceChange($0, countsPendingIncoming: countsPendingIncoming) },
            knownSince: knownSince,
            transactions: transactions
        )
    }
}

/// JSON-friendly mirror of `MoneroTransaction` for the hardware-session
/// tx snapshot. The runtime type uses non-Codable enums; this mirror
/// flattens them into raw strings/ints for round-tripping through disk.
struct MoneroTransactionSnapshot: Codable {
    let id: String
    let typeRaw: String   // "incoming" / "outgoing"
    let amount: Decimal
    let fee: Decimal
    let address: String
    let timestamp: Date
    let confirmations: Int?
    let statusRaw: String  // "pending" / "confirmed" / "failed"
    let memo: String?
    /// Optional — old snapshots written before this field was added
    /// decode it as `nil`, in which case the consumer falls back to
    /// the frozen `confirmations` value.
    let blockHeight: UInt64?
    /// Optional for the same reason: snapshots written before these
    /// two fields existed must still decode (synthesized Codable uses
    /// `decodeIfPresent` for optionals). A non-optional field here
    /// once made every old snapshot fail to decode and the whole
    /// hardware transaction list vanished.
    let destinations: [MoneroTransactionDestination]?
    let subaddressIndex: Int?

    init(from tx: MoneroTransaction) {
        self.id = tx.id
        self.typeRaw = tx.type == .incoming ? "incoming" : "outgoing"
        self.amount = tx.amount
        self.fee = tx.fee
        self.address = tx.address
        self.timestamp = tx.timestamp
        self.confirmations = tx.confirmations
        switch tx.status {
        case .pending: self.statusRaw = "pending"
        case .confirmed: self.statusRaw = "confirmed"
        case .failed: self.statusRaw = "failed"
        }
        self.memo = tx.memo
        self.blockHeight = tx.blockHeight
        self.destinations = tx.destinations
        self.subaddressIndex = tx.subaddressIndex
    }

    func toTransaction() -> MoneroTransaction {
        let type: MoneroTransaction.TransactionType = typeRaw == "outgoing" ? .outgoing : .incoming
        let status: MoneroTransaction.TransactionStatus
        switch statusRaw {
        case "confirmed": status = .confirmed
        case "failed": status = .failed
        default: status = .pending
        }
        return MoneroTransaction(
            id: id,
            type: type,
            amount: amount,
            fee: fee,
            address: address,
            timestamp: timestamp,
            confirmations: confirmations,
            status: status,
            memo: memo,
            blockHeight: blockHeight,
            destinations: destinations ?? [],
            subaddressIndex: subaddressIndex
        )
    }
}
