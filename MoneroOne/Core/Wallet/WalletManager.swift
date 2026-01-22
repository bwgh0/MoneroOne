import Foundation
import SwiftUI
import Combine
import HdWalletKit
import MoneroKit

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
    @Published var currentSyncMode: SyncMode = .lite
    @Published var isSendReady: Bool = false
    @Published var sendSyncProgress: Double = 0
    @Published var sendSyncStatus: String = "Connecting..."

    enum SyncState: Equatable {
        case idle
        case connecting
        case syncing(progress: Double, remaining: Int?)
        case synced
        case error(String)
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

    // MARK: - Sync Mode
    var syncMode: SyncMode {
        SyncMode(rawValue: UserDefaults.standard.string(forKey: "syncMode") ?? SyncMode.privacy.rawValue) ?? .privacy
    }

    // MARK: - Private
    private let keychain = KeychainStorage()
    private var moneroWallet: MoneroWallet?
    private var liteWalletManager: LiteWalletManager?
    private var cancellables = Set<AnyCancellable>()
    private var currentSeed: [String]?

    // MARK: - Init

    init() {
        checkForExistingWallet()
    }

    private func checkForExistingWallet() {
        hasWallet = keychain.hasSeed()
    }

    // MARK: - Wallet Creation

    /// Generate a new 25-word Monero mnemonic using HdWalletKit
    func generateNewWallet() -> [String] {
        // Monero uses 25-word seeds (256 bits entropy + checksum)
        // HdWalletKit generates standard BIP39 mnemonics
        do {
            let mnemonic = try Mnemonic.generate(wordCount: .twentyFour, language: .english)
            // Monero typically uses 25 words, but we'll use 24-word BIP39 which MoneroKit accepts
            return mnemonic
        } catch {
            // Fallback to simpler generation if HdWalletKit fails
            print("Mnemonic generation failed: \(error)")
            return []
        }
    }

    func saveWallet(mnemonic: [String], pin: String, restoreHeight: UInt64? = nil) throws {
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)

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

        // Calculate restore height from date (network-specific)
        if let date = restoreDate {
            let restoreHeight = MoneroWallet.restoreHeight(for: date)
            UserDefaults.standard.set(restoreHeight, forKey: "\(networkPrefix)restoreHeight")
        }

        hasWallet = true
    }

    private func validateMnemonic(_ mnemonic: [String]) -> Bool {
        // Accept 12, 24, or 25 word mnemonics
        let validCounts = [12, 24, 25]
        guard validCounts.contains(mnemonic.count) else { return false }

        // Validate against BIP39 word list
        do {
            try Mnemonic.validate(words: mnemonic)
            return true
        } catch {
            // Allow 25-word Monero seeds which may not pass BIP39 validation
            return mnemonic.count == 25
        }
    }

    // MARK: - Wallet Unlock

    func unlock(pin: String) throws {
        guard let seedPhrase = try keychain.getSeed(pin: pin) else {
            throw WalletError.invalidPin
        }

        let mnemonic = seedPhrase.split(separator: " ").map(String.init)
        currentSeed = mnemonic
        currentSyncMode = syncMode

        if syncMode == .lite {
            // Lite mode: use LWS for fast sync
            try startLiteMode(mnemonic: mnemonic)
        } else {
            // Privacy mode: use MoneroKit for local sync
            try startPrivacyMode(mnemonic: mnemonic)
        }

        isUnlocked = true
    }

    private func startLiteMode(mnemonic: [String]) throws {
        let restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil

        // Create MoneroWallet in light wallet mode - connects to LWS for output fetching
        // wallet2 will use LWS endpoints: /get_unspent_outs, /get_random_outs, /submit_raw_tx
        let wallet = MoneroWallet()
        let lwsURLString = ServerConfiguration.lwsServerURL(isTestnet: isTestnet)
        guard let lwsURL = URL(string: lwsURLString) else {
            throw WalletError.invalidMnemonic // TODO: Add proper error type for invalid URL
        }

        do {
            try wallet.createLightWallet(
                seed: mnemonic,
                lwsURL: lwsURL,
                restoreHeight: restoreHeight,
                resetSuffix: resetSuffix,
                networkType: networkType
            )
        } catch {
            throw WalletError.invalidMnemonic
        }

        // Get primary address - use pre-computed address since wallet2 hasn't started yet
        // Both should use the same legacySeedFromBip39 conversion
        let walletAddress = wallet.primaryAddress
        let runtimeAddr = wallet.runtimePrimaryAddress
        #if DEBUG
        print("[WalletManager] Lite mode initialized")
        #endif

        // Get view key for LiteWalletManager (balance/tx display)
        guard let viewKey = getViewKey(from: wallet) else {
            // Fallback to privacy mode if we can't get view key
            moneroWallet = wallet
            bindToWallet(wallet)
            return
        }

        // Store address for UI (use receive address for display, but primary for LWS)
        address = wallet.address.isEmpty ? walletAddress : wallet.address

        // Start lite wallet manager for fast balance/transaction display
        let liteManager = LiteWalletManager()
        liteWalletManager = liteManager
        bindToLiteWallet(liteManager)

        // Get restore height from UserDefaults (set during restore flow, network-specific)
        let savedRestoreHeight = UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight")
        let startHeight: UInt64? = savedRestoreHeight > 0 ? UInt64(savedRestoreHeight) : nil

        // Start async sync for balance/transaction display - use PRIMARY address to match wallet2
        Task {
            await liteManager.start(address: walletAddress, viewKey: viewKey, isTestnet: isTestnet, startHeight: startHeight)
        }

        // Keep reference to MoneroWallet for sending
        // In light wallet mode, wallet2 automatically fetches outputs from LWS when sending
        moneroWallet = wallet

        // Don't set isSendReady = true immediately - wallet2 initializes asynchronously
        // Subscribe to wallet sync state changes to know when it's ready
        isSendReady = false
        sendSyncProgress = 0
        sendSyncStatus = "Initializing wallet..."

        // Subscribe to MoneroWallet's sync state - when it changes from idle, wallet2 is ready
        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .idle:
                    // Still initializing
                    self.sendSyncStatus = "Initializing wallet..."
                case .connecting:
                    // wallet2 is running and trying to connect
                    self.sendSyncStatus = "Connecting to light wallet server..."
                    self.sendSyncProgress = 30
                case .syncing(let progress, _):
                    // wallet2 is fetching from LWS
                    self.sendSyncProgress = 30 + progress * 0.7
                    self.sendSyncStatus = "Syncing..."
                case .synced:
                    // wallet2 is ready
                    self.isSendReady = true
                    self.sendSyncProgress = 100
                    self.sendSyncStatus = "Ready"
                case .error(let msg):
                    // If we get an error like "no connection to daemon", that's expected for light wallet
                    // The wallet is still usable for sending in light mode
                    if msg.lowercased().contains("no connection") || msg.lowercased().contains("timeout") {
                        NSLog("[WalletManager] Light wallet got expected connection error, marking as send-ready: \(msg)")
                        self.isSendReady = true
                        self.sendSyncProgress = 100
                        self.sendSyncStatus = "Ready (lite mode)"
                    } else {
                        self.sendSyncStatus = "Error: \(msg)"
                    }
                }
            }
            .store(in: &cancellables)

        // Note: wallet.start() is already called by createLightWallet() -> setupKit()
        // No need for redundant start() call here
    }

    private func startPrivacyMode(mnemonic: [String]) throws {
        let wallet = MoneroWallet()
        let restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil

        do {
            try wallet.create(seed: mnemonic, restoreHeight: restoreHeight, resetSuffix: resetSuffix, networkType: networkType)
        } catch {
            throw WalletError.invalidMnemonic
        }

        moneroWallet = wallet
        bindToWallet(wallet)
    }

    private func getViewKey(from wallet: MoneroWallet) -> String? {
        // MoneroKit exposes the secret view key through the kit
        let viewKey = wallet.secretViewKey
        #if DEBUG
        print("[WalletManager] getViewKey returned: \(viewKey != nil ? "valid" : "nil")")
        #endif
        return viewKey
    }

    private func bindToWallet(_ wallet: MoneroWallet) {
        // Bind wallet state to manager state
        wallet.$balance
            .receive(on: DispatchQueue.main)
            .assign(to: &$balance)

        wallet.$unlockedBalance
            .receive(on: DispatchQueue.main)
            .assign(to: &$unlockedBalance)

        wallet.$address
            .receive(on: DispatchQueue.main)
            .assign(to: &$address)

        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .map { state -> SyncState in
                switch state {
                case .idle: return .idle
                case .connecting: return .connecting
                case .syncing(let progress, let remaining):
                    return .syncing(progress: progress, remaining: remaining)
                case .synced: return .synced
                case .error(let msg): return .error(msg)
                }
            }
            .assign(to: &$syncState)

        wallet.$transactions
            .receive(on: DispatchQueue.main)
            .assign(to: &$transactions)

        wallet.$subaddresses
            .receive(on: DispatchQueue.main)
            .assign(to: &$subaddresses)

        // Set primary address
        primaryAddress = wallet.primaryAddress
    }

    private func bindToLiteWallet(_ manager: LiteWalletManager) {
        // Bind lite wallet manager state to WalletManager
        manager.$balance
            .receive(on: DispatchQueue.main)
            .assign(to: &$balance)

        manager.$unlockedBalance
            .receive(on: DispatchQueue.main)
            .assign(to: &$unlockedBalance)

        manager.$syncState
            .receive(on: DispatchQueue.main)
            .map { state -> SyncState in
                switch state {
                case .idle: return .idle
                case .connecting: return .connecting
                case .syncing(let progress, let remaining):
                    return .syncing(progress: progress, remaining: remaining)
                case .synced: return .synced
                case .error(let msg): return .error(msg)
                }
            }
            .assign(to: &$syncState)

        manager.$transactions
            .receive(on: DispatchQueue.main)
            .assign(to: &$transactions)
    }

    private func startBackgroundSync(_ wallet: MoneroWallet) {
        // Helper to update send readiness from sync state
        func updateSendReadiness(from state: MoneroWallet.SyncState) {
            switch state {
            case .synced:
                isSendReady = true
                sendSyncProgress = 100
            case .syncing(let progress, _):
                sendSyncProgress = progress
                // Consider ready once we have most outputs synced
                isSendReady = progress >= 95
            case .connecting:
                sendSyncProgress = 0
                isSendReady = false
            case .error:
                // Keep current progress, don't mark as ready
                isSendReady = false
            case .idle:
                sendSyncProgress = 0
                isSendReady = false
            }
        }

        // Check initial state immediately (since @Published doesn't emit on subscribe)
        updateSendReadiness(from: wallet.syncState)

        // Subscribe to MoneroKit sync state changes for send readiness
        wallet.$syncState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateSendReadinessFromState(state)
            }
            .store(in: &cancellables)

        // Start MoneroKit sync to fetch outputs for transaction construction
        wallet.start()
    }

    private func updateSendReadinessFromState(_ state: MoneroWallet.SyncState) {
        switch state {
        case .synced:
            isSendReady = true
            sendSyncProgress = 100
            sendSyncStatus = "Ready"
        case .syncing(let progress, let remaining):
            sendSyncProgress = progress
            isSendReady = progress >= 95
            if let blocks = remaining {
                sendSyncStatus = "Syncing... \(blocks) blocks remaining"
            } else {
                sendSyncStatus = "Syncing blockchain..."
            }
        case .connecting:
            sendSyncStatus = "Connecting to node..."
        case .error(let msg):
            isSendReady = false
            sendSyncStatus = "Error: \(msg)"
        case .idle:
            sendSyncStatus = "Starting..."
        }
    }

    func lock() {
        moneroWallet?.stop()
        moneroWallet = nil
        liteWalletManager?.stop()
        liteWalletManager = nil
        currentSeed = nil
        isUnlocked = false
        balance = 0
        unlockedBalance = 0
        address = ""
        primaryAddress = ""
        syncState = .idle
        transactions = []
        subaddresses = []
        isSendReady = false
        sendSyncProgress = 0
        sendSyncStatus = "Connecting..."
    }

    // MARK: - Sync Mode Switching

    /// Switch sync mode and restart wallet
    func switchSyncMode(to mode: SyncMode) {
        guard let seed = currentSeed, mode != currentSyncMode else { return }

        // Release references - deinit handles cleanup
        // Don't call stop() here as deinit will do it (avoids double-close crash)
        moneroWallet = nil
        liteWalletManager = nil
        cancellables.removeAll()

        // Reset state
        syncState = .connecting
        balance = 0
        unlockedBalance = 0
        transactions = []
        isSendReady = false
        sendSyncProgress = 0
        sendSyncStatus = "Connecting..."

        currentSyncMode = mode

        // Restart with new mode
        do {
            if mode == .lite {
                try startLiteMode(mnemonic: seed)
            } else {
                try startPrivacyMode(mnemonic: seed)
            }
        } catch {
            syncState = .error("Failed to switch mode: \(error.localizedDescription)")
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
        return wallet.createSubaddress()
    }

    // MARK: - Validation

    func isValidAddress(_ address: String) -> Bool {
        MoneroWallet.isValidAddress(address, networkType: networkType)
    }

    // MARK: - Refresh

    func refresh() async {
        if currentSyncMode == .lite {
            await liteWalletManager?.refresh()
        } else {
            moneroWallet?.refresh()
        }
    }

    // MARK: - Node Management

    /// Node changes take effect immediately by restarting the connection
    func setNode(url: String, isTrusted: Bool = false) {
        UserDefaults.standard.set(url, forKey: "selectedNodeURL")
        // Restart sync with new node
        moneroWallet?.stop()
        moneroWallet?.start()
    }

    // MARK: - Seed Access

    func getSeedPhrase(pin: String) throws -> [String]? {
        guard let seedPhrase = try keychain.getSeed(pin: pin) else {
            return nil
        }
        return seedPhrase.split(separator: " ").map(String.init)
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
    func unlockWithBiometrics() throws {
        guard let pin = keychain.getPinWithBiometrics() else {
            throw WalletError.biometricFailed
        }
        try unlock(pin: pin)
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

        if currentSyncMode == .lite {
            // Lite mode: stop lite manager and MoneroWallet, re-register with server
            liteWalletManager?.stop()
            liteWalletManager = nil
            moneroWallet?.stop()
            moneroWallet = nil

            // Clear MoneroKit wallet data directory for light wallet
            clearWalletCache()

            // Increment reset counter to force new walletId (network-specific)
            let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount") + 1
            UserDefaults.standard.set(resetCount, forKey: "\(networkPrefix)syncResetCount")

            do {
                try startLiteMode(mnemonic: seed)
            } catch {
                syncState = .error("Failed to restart lite mode: \(error.localizedDescription)")
            }
        } else {
            // Privacy mode: restart MoneroKit with new wallet ID
            moneroWallet?.stop()
            moneroWallet = nil

            // Clear MoneroKit wallet data directory
            clearWalletCache()

            // Increment reset counter to force new walletId (network-specific)
            let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount") + 1
            UserDefaults.standard.set(resetCount, forKey: "\(networkPrefix)syncResetCount")

            // Get restore height from UserDefaults (network-specific)
            let restoreHeight = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))

            do {
                let wallet = MoneroWallet()
                try wallet.create(seed: seed, restoreHeight: restoreHeight, resetSuffix: "\(resetCount)", networkType: networkType)
                moneroWallet = wallet
                bindToWallet(wallet)
            } catch {
                syncState = .error("Failed to restart wallet: \(error.localizedDescription)")
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
        hasWallet = false
    }

    // MARK: - Network Switching

    /// Switch networks without clearing sync cache - each network maintains separate sync state
    func switchNetwork() {
        guard let seed = currentSeed else {
            syncState = .error("No wallet to switch")
            return
        }

        // Stop current wallet without clearing cache
        liteWalletManager?.stop()
        liteWalletManager = nil
        moneroWallet?.stop()
        moneroWallet = nil
        cancellables.removeAll()

        // Reset UI state
        balance = 0
        unlockedBalance = 0
        transactions = []
        syncState = .connecting
        isSendReady = false
        sendSyncProgress = 0
        sendSyncStatus = "Connecting..."

        // Reinitialize with new network (will use different walletId due to network suffix)
        // Note: isTestnet has already been toggled by the caller
        if currentSyncMode == .lite {
            do {
                try startLiteMode(mnemonic: seed)
            } catch {
                syncState = .error("Failed to start lite mode: \(error.localizedDescription)")
            }
        } else {
            do {
                try startPrivacyMode(mnemonic: seed)
            } catch {
                syncState = .error("Failed to start privacy mode: \(error.localizedDescription)")
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

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic: return "Invalid seed phrase"
        case .invalidPin: return "Invalid PIN"
        case .saveFailed: return "Failed to save wallet"
        case .notUnlocked: return "Wallet is locked"
        case .biometricFailed: return "Biometric authentication failed"
        }
    }
}
