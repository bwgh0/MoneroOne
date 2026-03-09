import Foundation
import SwiftUI
import Combine
import QuartzCore
import HdWalletKit
import MoneroKit
import CMonero
import WidgetKit

@MainActor
class WalletManager: ObservableObject {
    // MARK: - Published State
    @Published var hasWallet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var address: String = ""
    @Published var primaryAddress: String = ""
    @Published var syncState: SyncState = .idle
    @Published var transactions: [MoneroTransaction] = []
    @Published var subaddresses: [MoneroKit.SubAddress] = []
    @Published var userCreatedSubaddressIndices: Set<Int> = []
    @Published private(set) var walletSessionId = UUID()

    // Send prefill properties (for donation flow)
    @Published var prefillSendAddress: String?
    @Published var prefillSendAmount: String?
    @Published var shouldShowSendView: Bool = false

    // Connection progress tracking
    @Published var connectionStage: ConnectionStage = .noNetwork
    @Published var daemonHeight: UInt64 = 0
    @Published var walletHeight: UInt64 = 0
    @Published var restoreHeight: UInt64 = 0
    @Published var connectionElapsedSeconds: Int = 0
    private var nodeReachable: Bool? = nil  // nil = not tested, true/false = result
    private var networkMonitorCancellable: AnyCancellable?
    private var connectionTimer: Timer?
    private var connectionStartTime: Date?
    private var reachabilityRetryTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var reachabilityRetryCount: Int = 0
    private var currentReachabilityTask: URLSessionDataTask?
    private var lastSyncPublish: Double = 0

    /// URLSession that accepts all certificates (matches NodeManager behavior)
    /// Nodes with self-signed certs pass the settings latency test, so the wallet
    /// reachability test must also accept them to avoid a stuck "Reaching node..." state.
    private lazy var reachabilitySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: AllCertsTrustDelegate.shared, delegateQueue: nil)
    }()

    enum SyncState: Equatable {
        case idle
        case connecting
        case syncing(progress: Double, remaining: Int?)
        case synced
        case error(String)
    }


    /// Seed type for wallet creation/restoration
    enum SeedType: String, CaseIterable {
        case polyseed = "polyseed"  // 16 words with embedded birthday
        case bip39 = "bip39"        // 24 words (standard)
        case legacy = "legacy"      // 25 words (old Monero format)

        var wordCount: Int {
            switch self {
            case .polyseed: return 16
            case .bip39: return 24
            case .legacy: return 25
            }
        }

        /// Detect seed type from word count
        static func detect(from wordCount: Int) -> SeedType? {
            switch wordCount {
            case 16: return .polyseed
            case 24: return .bip39
            case 25: return .legacy
            default: return nil
            }
        }
    }

    // MARK: - Network Type
    var isTestnet: Bool {
        UserDefaults.standard.bool(forKey: "isTestnet")
    }

    var networkType: MoneroKit.NetworkType {
        isTestnet ? .testnet : .mainnet
    }

    /// Network-specific prefix for UserDefaults keys to keep testnet/mainnet data separate
    private var networkPrefix: String {
        isTestnet ? "testnet_" : "mainnet_"
    }

    // MARK: - Private
    private let keychain = KeychainStorage()
    private var moneroWallet: MoneroWallet?
    private var cancellables = Set<AnyCancellable>()
    private var currentSeed: [String]?
    private var isRefreshing = false
    private var widgetReloadTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        checkForExistingWallet()
    }

    private func checkForExistingWallet() {
        hasWallet = keychain.hasSeed()
    }

    // MARK: - Wallet Creation

    /// Generate a new 16-word Polyseed mnemonic using MoneroKit's native polyseed support
    /// Polyseed includes an embedded wallet birthday for faster restoration
    func generatePolyseed() -> [String] {
        guard let seedPtr = MONERO_Wallet_createPolyseed("English") else {
            #if DEBUG
            print("Polyseed generation failed: null pointer returned")
            #endif
            return []
        }
        let seedString = String(cString: seedPtr)
        let words = seedString.split(separator: " ").map(String.init)

        // Polyseed should always be 16 words
        guard words.count == 16 else {
            #if DEBUG
            print("Polyseed generation failed: expected 16 words, got \(words.count)")
            #endif
            return []
        }

        return words
    }

    /// Generate a new 24-word BIP39 mnemonic using HdWalletKit
    /// This is the standard format, kept for backward compatibility
    func generateBip39Seed() -> [String] {
        do {
            let mnemonic = try Mnemonic.generate(wordCount: .twentyFour, language: .english)
            return mnemonic
        } catch {
            #if DEBUG
            print("BIP39 mnemonic generation failed: \(error)")
            #endif
            return []
        }
    }

    /// Generate a new wallet seed (defaults to Polyseed for new wallets)
    /// - Parameter type: The seed type to generate (defaults to polyseed)
    /// - Returns: Array of seed words
    func generateNewWallet(type: SeedType = .polyseed) -> [String] {
        switch type {
        case .polyseed:
            return generatePolyseed()
        case .bip39, .legacy:
            return generateBip39Seed()
        }
    }

    func saveWallet(mnemonic: [String], pin: String, restoreHeight: UInt64? = nil) throws {
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)

        // Auto-detect and save seed type based on word count
        if let seedType = SeedType.detect(from: mnemonic.count) {
            UserDefaults.standard.set(seedType.rawValue, forKey: "\(networkPrefix)seedType")
        }

        // Save restore height if provided (network-specific)
        if let height = restoreHeight {
            UserDefaults.standard.set(height, forKey: "\(networkPrefix)restoreHeight")
        }

        hasWallet = true
    }

    func restoreWallet(mnemonic: [String], pin: String, restoreDate: Date? = nil) throws {
        guard validateMnemonic(mnemonic) else {
            throw WalletError.invalidMnemonic
        }

        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)

        // Auto-detect and save seed type based on word count
        if let seedType = SeedType.detect(from: mnemonic.count) {
            UserDefaults.standard.set(seedType.rawValue, forKey: "\(networkPrefix)seedType")
        }

        // Calculate restore height from date (network-specific)
        // Note: Polyseed (16 words) has embedded birthday, so restoreDate is optional for it
        if let date = restoreDate {
            let restoreHeight = MoneroWallet.restoreHeight(for: date)
            UserDefaults.standard.set(restoreHeight, forKey: "\(networkPrefix)restoreHeight")
        }

        hasWallet = true
    }

    private func validateMnemonic(_ mnemonic: [String]) -> Bool {
        // Accept 16 (polyseed), 24 (BIP39), or 25 (legacy Monero) word mnemonics
        let validCounts = [16, 24, 25]
        guard validCounts.contains(mnemonic.count) else { return false }

        // Polyseed (16 words) uses its own word list, so skip BIP39 validation
        if mnemonic.count == 16 {
            return true
        }

        // Validate against BIP39 word list for 24-word seeds
        do {
            try Mnemonic.validate(words: mnemonic)
            return true
        } catch {
            // Allow 25-word legacy Monero seeds which don't pass BIP39 validation
            return mnemonic.count == 25
        }
    }

    // MARK: - Wallet Unlock

    func unlock(pin: String) async throws {
        guard let seedPhrase = try keychain.getSeed(pin: pin) else {
            throw WalletError.invalidPin
        }

        let mnemonic = seedPhrase.split(separator: " ").map(String.init)
        currentSeed = mnemonic

        // Start privacy mode wallet
        let wallet = MoneroWallet()
        let walletRestoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil

        do {
            try await wallet.create(seed: mnemonic, restoreHeight: walletRestoreHeight, resetSuffix: resetSuffix, networkType: networkType)
        } catch {
            throw WalletError.invalidMnemonic
        }

        // Try to get address from wallet - may be empty initially for polyseed until wallet opens
        // The address will be populated via delegate callback when Kit._start() runs
        let runtimeAddress = wallet.primaryAddress
        if !runtimeAddress.isEmpty {
            self.primaryAddress = runtimeAddress
        }

        moneroWallet = wallet
        bindToWallet(wallet)

        // Load user-created subaddress indices for filtering in UI
        loadUserCreatedSubaddresses()

        // Start connection progress tracking
        restoreHeight = walletRestoreHeight
        startConnectionTracking()

        isUnlocked = true
        walletSessionId = UUID()
    }

    private func bindToWallet(_ wallet: MoneroWallet) {
        // Bind wallet state to manager state with widget updates
        wallet.$balance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newBalance in
                guard let self = self else { return }
                self.balance = newBalance
                // Update widget when balance changes while synced
                if case .synced = self.syncState {
                    self.saveWidgetDataIfEnabled()
                }
            }
            .store(in: &cancellables)

        wallet.$unlockedBalance
            .receive(on: DispatchQueue.main)
            .assign(to: &$unlockedBalance)

        wallet.$address
            .receive(on: DispatchQueue.main)
            .assign(to: &$address)

        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }

                // When sync is blocked, ignore state updates from the engine
                // (wallet2 may fire trailing callbacks after pauseRefresh)
                if self.isSyncBlocked { return }

                let newState: SyncState
                switch state {
                case .idle: newState = .idle
                case .connecting: newState = .connecting
                case .syncing(let progress, let remaining):
                    newState = .syncing(progress: progress, remaining: remaining)
                case .synced: newState = .synced
                case .error(let msg): newState = .error(msg)
                }

                // Don't let the wallet's initial .idle publish regress from .connecting
                // during a restart — restartWallet() sets .connecting manually before
                // the new wallet is created, so the first .idle from wallet2 is stale.
                if case .idle = newState, case .connecting = self.syncState {
                    return
                }

                // Throttle rapid syncing progress updates to prevent SwiftUI
                // view re-renders from swallowing NavigationLink taps.
                // State transitions (idle/connecting/synced/error) pass immediately.
                if case .syncing = newState, case .syncing = self.syncState {
                    let now = CACurrentMediaTime()
                    if now - self.lastSyncPublish < 0.25 { return }
                    self.lastSyncPublish = now
                }

                self.syncState = newState

                // wallet2 C++ is connecting — cancel HTTP reachability checks
                // since wallet2 handles TLS/connection independently
                if case .connecting = newState {
                    self.reachabilityRetryTask?.cancel()
                    self.reachabilityRetryTask = nil
                    self.currentReachabilityTask?.cancel()
                    self.currentReachabilityTask = nil
                }

                // Update connection stage based on sync state
                self.updateConnectionStage()

                // Update widget when sync completes
                if case .synced = newState {
                    self.saveWidgetDataIfEnabled()
                }
            }
            .store(in: &cancellables)

        // Track block heights for connection progress
        wallet.$daemonHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self else { return }
                self.daemonHeight = height
                self.updateConnectionStage()
            }
            .store(in: &cancellables)

        wallet.$walletHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self else { return }
                self.walletHeight = height
                self.updateConnectionStage()
            }
            .store(in: &cancellables)

        wallet.$transactions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTransactions in
                guard let self = self else { return }
                self.transactions = newTransactions
                // Update widget when transactions change while synced
                if case .synced = self.syncState {
                    self.saveWidgetDataIfEnabled()
                }
            }
            .store(in: &cancellables)

        wallet.$subaddresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSubaddresses in
                guard let self = self else { return }
                self.subaddresses = newSubaddresses
                let hasValidIdx0 = newSubaddresses.contains { $0.index == 0 && !$0.address.isEmpty }
                #if DEBUG
                NSLog("[WalletManager] $subaddresses: count=%d hasValidIdx0=%d primaryAddr.empty=%d", newSubaddresses.count, hasValidIdx0 ? 1 : 0, self.primaryAddress.isEmpty ? 1 : 0)
                #endif
                // Update primaryAddress when subaddresses change (polyseed case - addresses populate after wallet opens)
                if let primary = newSubaddresses.first(where: { $0.index == 0 && !$0.address.isEmpty }) {
                    if self.primaryAddress.isEmpty {
                        #if DEBUG
                        NSLog("[WalletManager] SETTING primaryAddress from subaddresses sink")
                        #endif
                        self.primaryAddress = primary.address
                    }
                }
                // Note: Subaddress 1 auto-creation is handled explicitly after bindToWallet() with delay
                // to ensure polyseed wallets have time to initialize addresses asynchronously
            }
            .store(in: &cancellables)

        // Set primary address immediately if available
        primaryAddress = wallet.primaryAddress

        // Also update primaryAddress when sync state changes (kit may not be ready initially)
        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let addr = wallet.primaryAddress
                if !addr.isEmpty && self.primaryAddress.isEmpty {
                    self.primaryAddress = addr
                }
            }
            .store(in: &cancellables)
    }

    func lock() {
        // Cancel Combine subscriptions FIRST — they hold strong refs to the old wallet
        cancellables.removeAll()

        // Capture old wallet so its deallocation (Kit.deinit → C++ close)
        // happens off the main thread.
        let oldWallet = moneroWallet
        moneroWallet = nil
        Task.detached { [oldWallet] in let _ = oldWallet }

        currentSeed = nil
        isUnlocked = false
        balance = 0
        unlockedBalance = 0
        address = ""
        primaryAddress = ""
        syncState = .idle
        transactions = []
        subaddresses = []

        // Reset connection progress tracking
        connectionStage = .noNetwork
        daemonHeight = 0
        walletHeight = 0
        nodeReachable = nil
        reachabilityRetryCount = 0
        reachabilityRetryTask?.cancel()
        reachabilityRetryTask = nil
        networkMonitorCancellable?.cancel()
        networkMonitorCancellable = nil
    }

    // MARK: - Connection Stage

    /// Update connection stage based on REAL detection, not timers
    /// Called when sync state, heights, or network status change
    private func updateConnectionStage() {
        // Stage 6: Synced
        if case .synced = syncState {
            connectionStage = .synced
            return
        }

        // Stage 5: Syncing
        if case .syncing = syncState {
            connectionStage = .syncing
            return
        }

        // Stage 4: Got daemon height, loading blocks - show wallet height climbing
        if daemonHeight > 0 {
            // If wallet has caught up to daemon, show syncing (waiting for C++ synchronized flag)
            if walletHeight >= daemonHeight {
                connectionStage = .syncing
            } else {
                connectionStage = .loadingBlocks(wallet: walletHeight, daemon: daemonHeight)
            }
            return
        }

        // Stage 3b: MoneroKit reports actively connecting - trust it over HTTP test
        if case .connecting = syncState {
            #if DEBUG
            NSLog("[WalletManager] MoneroKit reports .connecting — overriding reachability (nodeReachable=%@)", String(describing: nodeReachable))
            #endif
            connectionStage = .connecting
            return
        }

        // Stage 3: Node reachable but daemon not yet responding
        if nodeReachable == true {
            connectionStage = .connecting
            return
        }

        // Stage 2: Node not reachable — schedule retry
        if nodeReachable == false {
            connectionStage = .reachingNode
            scheduleReachabilityRetry()
            return
        }

        // Stage 1: Network check
        if !NetworkMonitor.shared.isConnected {
            connectionStage = .noNetwork
            return
        }

        // Default: trying to reach node
        connectionStage = .reachingNode
        testNodeReachability()
    }

    /// Start connection stage tracking when wallet unlocks
    private func startConnectionTracking() {
        // Load restore height for stage calculation
        restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))

        // Reset node reachability and retry state
        nodeReachable = nil
        reachabilityRetryCount = 0
        reachabilityRetryTask?.cancel()
        reachabilityRetryTask = nil
        currentReachabilityTask?.cancel()
        currentReachabilityTask = nil

        // Subscribe to network connectivity changes
        networkMonitorCancellable = NetworkMonitor.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self else { return }
                #if DEBUG
                NSLog("[WalletManager] Network connectivity changed: %@", isConnected ? "connected" : "disconnected")
                #endif
                if !isConnected {
                    self.nodeReachable = nil
                }
                self.updateConnectionStage()
            }

        // Initial stage update
        updateConnectionStage()
    }

    /// Test if the node is reachable via HTTP GET to /get_info
    private func testNodeReachability() {
        // Get node URL from UserDefaults
        #if DEBUG
        let defaultURL = isTestnet ? "http://testnet.xmr-tw.org:28081" : "https://node.monero.one:443"
        #else
        let defaultURL = "https://node.monero.one:443"
        #endif
        let nodeURLString = UserDefaults.standard.string(forKey: isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL")
            ?? defaultURL

        guard let baseURL = URL(string: nodeURLString) else {
            nodeReachable = false
            updateConnectionStage()
            return
        }

        let infoURL = baseURL.appendingPathComponent("get_info")
        var request = URLRequest(url: infoURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        // Cancel any in-flight reachability check to avoid stale results
        currentReachabilityTask?.cancel()

        let task = reachabilitySession.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Ignore cancelled requests (stale checks from previous node)
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    #if DEBUG
                    NSLog("[WalletManager] Reachability check cancelled (stale), ignoring")
                    #endif
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["height"] != nil || json["status"] != nil {
                    #if DEBUG
                    NSLog("[WalletManager] Node reachable: %@", nodeURLString)
                    #endif
                    self.nodeReachable = true
                    self.reachabilityRetryCount = 0
                    self.reachabilityRetryTask?.cancel()
                    self.reachabilityRetryTask = nil
                } else {
                    #if DEBUG
                    NSLog("[WalletManager] Node unreachable: %@ (HTTP %d)", nodeURLString, (response as? HTTPURLResponse)?.statusCode ?? 0)
                    #endif
                    self.nodeReachable = false
                }
                self.updateConnectionStage()
            }
        }
        currentReachabilityTask = task
        task.resume()
    }

    /// Retry reachability test with exponential backoff (5s, 10s, 20s)
    private func scheduleReachabilityRetry() {
        // Don't schedule if already retrying or max attempts reached
        guard reachabilityRetryTask == nil, reachabilityRetryCount < 3 else { return }

        let delay: UInt64 = switch reachabilityRetryCount {
        case 0: 5_000_000_000   // 5s
        case 1: 10_000_000_000  // 10s
        default: 20_000_000_000 // 20s
        }

        reachabilityRetryCount += 1
        #if DEBUG
        NSLog("[WalletManager] Scheduling reachability retry %d/3 in %ds", reachabilityRetryCount, delay / 1_000_000_000)
        #endif

        reachabilityRetryTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self.reachabilityRetryTask = nil
            self.testNodeReachability()
        }
    }

    // MARK: - Widget Data

    /// Save current wallet data for home screen widget
    /// - Parameter enabled: Override the enabled state. If nil, reads from UserDefaults.
    func saveWidgetData(enabled: Bool? = nil) {
        // Use passed value, or check UserDefaults
        let isEnabled = enabled ?? UserDefaults.standard.bool(forKey: "widgetEnabled")

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4

        let balanceFormatted = formatter.string(from: balance as NSDecimalNumber) ?? "0.0000"

        // Convert sync state to widget sync status
        let widgetSyncStatus: WidgetData.SyncStatus
        switch syncState {
        case .synced:
            widgetSyncStatus = .synced
        case .syncing:
            widgetSyncStatus = .syncing
        case .connecting:
            widgetSyncStatus = .connecting
        case .idle, .error:
            widgetSyncStatus = .offline
        }

        // Convert recent transactions
        let recentTransactions = transactions.prefix(5).map { tx in
            WidgetTransaction(
                id: tx.id,
                isIncoming: tx.type == .incoming,
                amount: tx.amount,
                amountFormatted: formatter.string(from: tx.amount as NSDecimalNumber) ?? "0.0000",
                timestamp: tx.timestamp,
                isConfirmed: (tx.confirmations ?? 0) >= 10
            )
        }

        // Load existing data to preserve price fields from PriceService
        var widgetData = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder

        // Update wallet-related fields only
        widgetData.balance = balance
        widgetData.balanceFormatted = balanceFormatted
        widgetData.syncStatus = widgetSyncStatus
        widgetData.lastUpdated = Date()
        widgetData.recentTransactions = Array(recentTransactions)
        widgetData.isTestnet = isTestnet
        widgetData.isEnabled = isEnabled

        WidgetDataManager.shared.save(widgetData)
    }

    /// Save widget data if widget is enabled - called during sync cycles
    /// Debounced: batches rapid updates into a single save + reload after 1 second
    private func saveWidgetDataIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "widgetEnabled") else { return }

        // Debounce: cancel any pending save and schedule a new one.
        // This avoids JSON encode + file I/O on every balance/tx/state change.
        widgetReloadTask?.cancel()
        widgetReloadTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            guard !Task.isCancelled else { return }
            self.saveWidgetData()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Send

    func estimateFee(to address: String, amount: Decimal) async throws -> Decimal {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.estimateFee(to: address, amount: amount)
    }

    func send(to address: String, amount: Decimal, memo: String? = nil) async throws -> String {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.send(to: address, amount: amount, memo: memo)
    }

    func sendAll(to address: String, memo: String? = nil) async throws -> String {
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.sendAll(to: address, memo: memo)
    }

    // MARK: - Subaddresses

    /// Create a new subaddress for receiving payments
    /// - Returns: The newly created SubAddress, or nil if creation failed
    func createSubaddress() -> MoneroKit.SubAddress? {
        guard let wallet = moneroWallet else { return nil }
        if let newSubaddr = wallet.createSubaddress() {
            userCreatedSubaddressIndices.insert(newSubaddr.index)
            saveUserCreatedSubaddresses()
            return newSubaddr
        }
        return nil
    }

    // MARK: - User-Created Subaddress Persistence

    private func saveUserCreatedSubaddresses() {
        UserDefaults.standard.set(Array(userCreatedSubaddressIndices), forKey: "\(networkPrefix)userCreatedSubaddressIndices")
    }

    private func loadUserCreatedSubaddresses() {
        let saved = UserDefaults.standard.array(forKey: "\(networkPrefix)userCreatedSubaddressIndices") as? [Int] ?? []
        userCreatedSubaddressIndices = Set(saved)
    }

    // MARK: - Validation

    func isValidAddress(_ address: String) -> Bool {
        MoneroWallet.isValidAddress(address, networkType: networkType)
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing, !isSyncBlocked else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // If stuck on unreachable, reset and re-test (user escape hatch)
        if nodeReachable == false {
            #if DEBUG
            NSLog("[WalletManager] Pull-to-refresh: resetting stuck reachability state")
            #endif
            nodeReachable = nil
            reachabilityRetryCount = 0
            reachabilityRetryTask?.cancel()
            reachabilityRetryTask = nil
            updateConnectionStage()
        }

        // Let MoneroKit determine actual sync state via walletStateDidChange() callback
        // Don't force .connecting - if already synced and no new blocks, stay synced
        moneroWallet?.startSync()
        moneroWallet?.refresh()
        // Note: Live Activity is updated by TrustedLocationSyncManager.handleSyncStateChange()
        // when sync state transitions to .synced - no need to call markSynced() here
    }

    /// Restart sync to check for new blocks
    func startSync() {
        guard !isSyncBlocked else { return }
        moneroWallet?.startSync()
    }

    /// Whether sync is blocked (e.g. outside trusted zone in block mode)
    /// When true, startSync() and refresh() become no-ops
    var isSyncBlocked: Bool = false

    /// Pause sync — stops refresh and state polling
    func pauseSync() {
        isSyncBlocked = true
        moneroWallet?.pauseSync()
        syncState = .idle
    }

    /// Resume sync capability (does not start sync, just unblocks it)
    func resumeSync() {
        isSyncBlocked = false
    }

    // MARK: - Node Management

    /// Set node URL and restart wallet to use new node immediately
    @discardableResult
    func setNode(url: String, isTrusted: Bool = false, login: String? = nil, password: String? = nil) -> Bool {
        UserDefaults.standard.set(url, forKey: isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL")
        UserDefaults.standard.set(login, forKey: isTestnet ? "selectedTestnetNodeLogin" : "selectedNodeLogin")
        UserDefaults.standard.set(password, forKey: isTestnet ? "selectedTestnetNodePassword" : "selectedNodePassword")

        if let seed = currentSeed {
            restartWallet(with: seed)
        }
        return true
    }

    // MARK: - Proxy Management

    /// Set SOCKS proxy address and restart wallet to apply
    func setProxy(_ address: String) {
        saveProxy(address)

        if let seed = currentSeed {
            restartWallet(with: seed)
        }
    }

    /// Save proxy address to UserDefaults without restarting the wallet.
    /// Use this when a subsequent setNode() call will trigger the restart.
    func saveProxy(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: "proxyAddress")
    }

    // MARK: - Wallet Restart

    /// Restart the wallet, serializing teardown → create to prevent dual C++ connections.
    /// The old wallet is stopped explicitly before the new one is created.
    /// Rapid re-entry (e.g. quick node switching) cancels the in-flight restart.
    private func restartWallet(with seed: [String]) {
        guard isUnlocked else { return }

        syncState = .connecting

        // Cancel any in-flight restart
        restartTask?.cancel()

        let oldWallet = moneroWallet
        moneroWallet = nil
        cancellables.removeAll()

        let walletRestoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil
        let netType = networkType

        restartTask = Task {
            // Stop old wallet explicitly — Kit.stop() queues MoneroCore.stop()
            // on lifecycleQueue, which calls MONERO_WalletManager_closeWallet()
            oldWallet?.stop()
            // Give lifecycleQueue time to process the C++ close
            try? await Task.sleep(nanoseconds: 100_000_000)

            // Another restart superseded this one
            guard !Task.isCancelled else { return }

            do {
                let wallet = MoneroWallet()
                try await wallet.create(seed: seed, restoreHeight: walletRestoreHeight,
                                  resetSuffix: resetSuffix, networkType: netType)

                // Check again — create() takes time, another restart may have fired
                guard !Task.isCancelled else {
                    wallet.stop()
                    return
                }

                self.moneroWallet = wallet
                self.bindToWallet(wallet)
                self.walletSessionId = UUID()
                self.startConnectionTracking()
            } catch {
                if !Task.isCancelled {
                    self.syncState = .error("Failed to reconnect: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Seed Access

    func getSeedPhrase(pin: String) throws -> [String]? {
        guard let seedPhrase = try keychain.getSeed(pin: pin) else {
            return nil
        }
        let mnemonic = seedPhrase.split(separator: " ").map(String.init)

        // CRITICAL: Verify seed matches the currently unlocked wallet
        // This is defense-in-depth since Fix #1 (network-prefixed keychain keys) already
        // prevents cross-network seed confusion. This check catches any remaining edge cases.
        if !primaryAddress.isEmpty, let currentSeedMnemonic = currentSeed {
            // Compare with the seed that was used to unlock the current wallet
            if mnemonic != currentSeedMnemonic {
                #if DEBUG
                NSLog("[WalletManager] CRITICAL: Keychain seed doesn't match unlocked wallet seed!")
                #endif
                throw WalletError.seedMismatch
            }
        }

        return mnemonic
    }

    // MARK: - Biometric Unlock

    /// Enable biometric unlock by storing PIN securely
    func enableBiometricUnlock(pin: String) throws {
        try keychain.savePinForBiometrics(pin)
    }

    /// Disable biometric unlock
    func disableBiometricUnlock() {
        keychain.deleteBiometricPin()
    }

    /// Check if biometric unlock is available
    var hasBiometricPinStored: Bool {
        keychain.hasBiometricPin()
    }

    /// Unlock using biometrics - retrieves PIN via Face ID/Touch ID
    func unlockWithBiometrics() async throws {
        guard let pin = keychain.getPinWithBiometrics() else {
            throw WalletError.biometricFailed
        }
        try await unlock(pin: pin)
    }

    // MARK: - Reset Sync

    func resetSyncData() {
        guard let seed = currentSeed else {
            syncState = .error("No wallet to reset")
            return
        }

        // Reset displayed state
        syncState = .connecting
        balance = 0
        unlockedBalance = 0
        transactions = []

        // Cancel Combine subscriptions — they hold strong refs to the old wallet
        cancellables.removeAll()

        // Capture old wallet so its deallocation happens off main thread
        let oldWallet = moneroWallet
        moneroWallet = nil
        Task.detached { [oldWallet] in let _ = oldWallet }

        // Clear MoneroKit wallet data directory
        clearWalletCache()

        // Increment reset counter to force new walletId (network-specific)
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount") + 1
        UserDefaults.standard.set(resetCount, forKey: "\(networkPrefix)syncResetCount")

        // Get restore height from UserDefaults (network-specific)
        let restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let netType = networkType

        // Create new wallet — Kit init runs off main via async create()
        Task {
            do {
                let wallet = MoneroWallet()
                try await wallet.create(seed: seed, restoreHeight: restoreHeight, resetSuffix: "\(resetCount)", networkType: netType)
                self.moneroWallet = wallet
                self.bindToWallet(wallet)
            } catch {
                self.syncState = .error("Failed to restart wallet: \(error.localizedDescription)")
            }
        }
    }

    private func clearWalletCache() {
        let fileManager = FileManager.default

        // Clear Library/Application Support/MoneroKit (where MoneroKit actually stores data)
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let moneroKitDir = appSupportURL.appendingPathComponent("MoneroKit")
            try? fileManager.removeItem(at: moneroKitDir)
        }

        // Also try lowercase variants just in case
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: documentsURL.appendingPathComponent("MoneroKit"))
            try? fileManager.removeItem(at: documentsURL.appendingPathComponent("monero-kit"))
        }

        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: cachesURL.appendingPathComponent("MoneroKit"))
        }
        // Note: Do NOT clear restoreHeight - user may have set a custom value
    }

    // MARK: - Delete Wallet

    func deleteWallet() {
        lock()
        keychain.deleteSeed()
        // Clear network-specific data for both networks
        UserDefaults.standard.removeObject(forKey: "mainnet_restoreHeight")
        UserDefaults.standard.removeObject(forKey: "testnet_restoreHeight")
        UserDefaults.standard.removeObject(forKey: "mainnet_syncResetCount")
        UserDefaults.standard.removeObject(forKey: "testnet_syncResetCount")
        UserDefaults.standard.removeObject(forKey: "mainnet_seedType")
        UserDefaults.standard.removeObject(forKey: "testnet_seedType")
        // Clear selected subaddress index (prevents stale index for next wallet)
        UserDefaults.standard.removeObject(forKey: "selectedSubaddressIndex")
        // Clear user-created subaddress indices
        UserDefaults.standard.removeObject(forKey: "mainnet_userCreatedSubaddressIndices")
        UserDefaults.standard.removeObject(forKey: "testnet_userCreatedSubaddressIndices")
        userCreatedSubaddressIndices = []
        hasWallet = false
    }

    // MARK: - Network Switching

    /// Switch networks without clearing sync cache - each network maintains separate sync state
    func switchNetwork() {
        guard let seed = currentSeed else {
            syncState = .error("No wallet to switch")
            return
        }

        // CRITICAL: Clear address fields FIRST to prevent stale address display if init fails
        address = ""
        primaryAddress = ""
        subaddresses = []

        // Capture old wallet so its deallocation happens off main thread
        let oldWallet = moneroWallet
        moneroWallet = nil
        cancellables.removeAll()
        Task.detached { [oldWallet] in let _ = oldWallet }

        // Reset UI state
        balance = 0
        unlockedBalance = 0
        transactions = []
        syncState = .connecting

        // Reinitialize with new network (will use different walletId due to network suffix)
        // Note: isTestnet has already been toggled by the caller
        let walletRestoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil
        let netType = networkType

        // Create new wallet — Kit init runs off main via async create()
        Task {
            do {
                let wallet = MoneroWallet()
                try await wallet.create(seed: seed, restoreHeight: walletRestoreHeight, resetSuffix: resetSuffix, networkType: netType)
                self.moneroWallet = wallet
                self.bindToWallet(wallet)
            } catch {
                self.syncState = .error("Failed to switch network: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Errors

enum WalletError: LocalizedError {
    case invalidMnemonic
    case invalidPin
    case saveFailed
    case notUnlocked
    case biometricFailed
    case seedMismatch  // Seed doesn't match current wallet address

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic: return "Invalid seed phrase"
        case .invalidPin: return "Invalid PIN"
        case .saveFailed: return "Failed to save wallet"
        case .notUnlocked: return "Wallet is locked"
        case .biometricFailed: return "Biometric authentication failed"
        case .seedMismatch: return "Seed phrase doesn't match current wallet"
        }
    }
}

// MARK: - Connection Stages

/// Connection stages for progressive UI feedback with REAL detection
/// Each stage represents a checkpoint in the connection process
enum ConnectionStage: Equatable {
    case noNetwork              // Stage 1: No network connectivity
    case reachingNode           // Stage 2: Testing node reachability
    case connecting             // Stage 3: Node reachable, waiting for daemon
    case loadingBlocks(wallet: UInt64, daemon: UInt64)  // Stage 4: Loading blocks
    case syncing                // Stage 5: Scanning blocks for transactions
    case synced                 // Stage 6: Fully synced

    var displayText: String {
        switch self {
        case .noNetwork: return "No network"
        case .reachingNode: return "Reaching node..."
        case .connecting: return "Connecting..."
        case .loadingBlocks(let wallet, let daemon):
            return "Loading... \(Self.formatHeight(wallet)) / \(Self.formatHeight(daemon))"
        case .syncing: return "Scanning..."
        case .synced: return "Synced"
        }
    }

    /// Stage index for the progress indicator (0-5)
    var stageIndex: Int {
        switch self {
        case .noNetwork: return 0
        case .reachingNode: return 1
        case .connecting: return 2
        case .loadingBlocks: return 3
        case .syncing: return 4
        case .synced: return 5
        }
    }

    private static func formatHeight(_ height: UInt64) -> String {
        if height >= 1_000_000 {
            return String(format: "%.2fM", Double(height) / 1_000_000)
        } else if height >= 1_000 {
            return String(format: "%.1fK", Double(height) / 1_000)
        }
        return "\(height)"
    }
}

// MARK: - URLSession Delegate for Node Reachability

/// Accepts all server certificates and handles digest auth for node reachability checks.
/// Matches the behavior of NodeManager's NWConnection latency tests,
/// which use `sec_protocol_options_set_verify_block { _, _, complete in complete(true) }`.
private class AllCertsTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = AllCertsTrustDelegate()

    // Session-level: TLS trust
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // Task-level: HTTP digest/basic auth (monerod uses digest)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ||
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            // Only attempt credentials once to avoid loops
            guard challenge.previousFailureCount == 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let isTestnet = UserDefaults.standard.bool(forKey: "isTestnet")
            let login = UserDefaults.standard.string(forKey: isTestnet ? "selectedTestnetNodeLogin" : "selectedNodeLogin")
            let password = UserDefaults.standard.string(forKey: isTestnet ? "selectedTestnetNodePassword" : "selectedNodePassword")
            if let login = login, !login.isEmpty {
                let credential = URLCredential(user: login, password: password ?? "", persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
