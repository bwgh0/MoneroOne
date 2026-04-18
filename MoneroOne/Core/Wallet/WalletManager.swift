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
    @Published var wallets: [WalletInfo] = []
    @Published var activeWallet: WalletInfo?
    var hasWallet: Bool { !wallets.isEmpty }
    @Published var isUnlocked: Bool = false
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var address: String = ""
    @Published var primaryAddress: String = ""
    @Published var syncState: SyncState = .idle
    @Published var transactions: [MoneroTransaction] = []
    @Published var subaddresses: [MoneroKit.SubAddress] = []
    @Published var userCreatedSubaddressIndices: Set<Int> = []
    /// True when the active wallet was opened from an address + view key and
    /// has no spend key on-device. Drives `SendFlow` disable + UI badges.
    /// Derived from `activeWallet?.source` in the start paths; a hardware
    /// wallet variant later flips this to `false` too via the same property.
    @Published private(set) var isViewOnly: Bool = false
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
    private var lastHeightPublish: Double = 0
    private var errorDebounceTask: Task<Void, Never>?

    /// URLSession that accepts all certificates (matches NodeManager behavior)
    /// Nodes with self-signed certs pass the settings latency test, so the wallet
    /// reachability test must also accept them to avoid a stuck "Reaching node..." state.
    private lazy var reachabilitySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: AllCertsTrustDelegate.shared, delegateQueue: nil)
    }()

    /// URLSession with standard TLS validation — used for diagnostic comparison.
    /// If this fails but reachabilitySession succeeds, the node has a cert issue
    /// that wallet2 C++ will also fail on.
    private lazy var strictTLSSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
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
    private let walletStore = WalletStore()
    private var moneroWallet: MoneroWallet?
    private var cancellables = Set<AnyCancellable>()
    private var currentSeed: [String]?
    private var currentPin: String?
    private var isRefreshing = false
    private var widgetReloadTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        checkForExistingWallet()
    }

    private func checkForExistingWallet() {
        var loaded = walletStore.loadWallets()

        // Migration: single-wallet → multi-wallet
        if loaded.isEmpty && keychain.hasSeed() {
            loaded = migrateFromSingleWallet()
        }

        // One-time scrub of legacy global keychain entries for installs that
        // migrated before the wipe-on-migrate fix shipped. Idempotent and
        // guarded by its own flag so it runs exactly once per install.
        if !loaded.isEmpty && !UserDefaults.standard.bool(forKey: "one.monero.legacyKeychainWiped") {
            keychain.wipeLegacyGlobalSeedEntries()
            UserDefaults.standard.set(true, forKey: "one.monero.legacyKeychainWiped")
        }

        self.wallets = loaded

        if let activeId = walletStore.activeWalletId,
           let active = loaded.first(where: { $0.id == activeId }) {
            self.activeWallet = active
        } else if let first = loaded.first {
            self.activeWallet = first
            walletStore.setActiveWalletId(first.id)
        }
    }

    /// One-time migration from legacy single-wallet storage to multi-wallet
    private func migrateFromSingleWallet() -> [WalletInfo] {
        let seedTypeRaw = UserDefaults.standard.string(forKey: "\(networkPrefix)seedType") ?? "polyseed"
        let restoreH = UInt64(UserDefaults.standard.integer(forKey: "\(networkPrefix)restoreHeight"))
        let resetCount = UserDefaults.standard.integer(forKey: "\(networkPrefix)syncResetCount")
        let subaddrIndices = UserDefaults.standard.array(forKey: "\(networkPrefix)userCreatedSubaddressIndices") as? [Int] ?? []

        let source = (try? WalletSource(rawString: seedTypeRaw)) ?? .seed(.polyseed)

        let walletId = UUID()
        let info = WalletInfo(
            id: walletId,
            name: "Personal Wallet",
            source: source,
            createdAt: Date(),
            restoreHeight: restoreH,
            syncResetCount: resetCount,
            userCreatedSubaddressIndices: subaddrIndices,
            cachedPrimaryAddress: nil,
            cachedBalance: nil
        )

        // Copy keychain data from legacy keys to wallet-ID-scoped keys
        let legacyPrefix = "one.monero.MoneroOne.\(isTestnet ? "testnet" : "mainnet")"
        let newPrefix = info.keychainPrefix
        keychain.copyKeychainData(fromAccount: "\(legacyPrefix).seed", toAccount: "\(newPrefix).seed")
        keychain.copyKeychainData(fromAccount: "\(legacyPrefix).pinhash", toAccount: "\(newPrefix).pinhash")
        keychain.copyKeychainData(fromAccount: "\(legacyPrefix).salt", toAccount: "\(newPrefix).salt")

        // Wipe the originals — leaving them in place means the legacy seed
        // is still readable from the global slot and the fallback unlock
        // path could silently hand it to a future install with a corrupted
        // WalletInfo list. Wipe both networks since the active one could
        // change before the opposite network's migration runs.
        keychain.wipeLegacyGlobalSeedEntries()
        UserDefaults.standard.set(true, forKey: "one.monero.legacyKeychainWiped")

        walletStore.saveWallets([info])
        walletStore.setActiveWalletId(walletId)
        UserDefaults.standard.set(true, forKey: "one.monero.walletStore.migrated")

        return [info]
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

    func addWallet(name: String, emoji: String = "\u{1F4B0}", mnemonic: [String], pin: String, restoreHeight: UInt64? = nil) throws {
        let seedPhrase = mnemonic.joined(separator: " ")

        // Dedupe on the on-disk wallet ID (SHA-256 of seed+network) rather
        // than the previous PIN-dependent seed comparison. Two wallets with
        // the same seed map to the same wallet2 `.keys` cache file, so we
        // must reject before save to prevent two WalletInfo entries from
        // both pointing at the same on-disk wallet (which would corrupt
        // restore-height, sync state, and make delete-one nuke-both).
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let candidateDerivedId = MoneroWallet.stableWalletId(for: seedPhrase + networkSuffix)
        try checkForDuplicateSeed(seedPhrase: seedPhrase, derivedId: candidateDerivedId, pin: pin)

        let walletId = UUID()
        let info = WalletInfo(
            id: walletId,
            name: name,
            emoji: emoji,
            source: .seeded(wordCount: mnemonic.count),
            createdAt: Date(),
            restoreHeight: restoreHeight ?? 0,
            syncResetCount: 0,
            userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: nil,
            cachedBalance: nil,
            derivedWalletId: candidateDerivedId
        )

        try keychain.saveSeed(seedPhrase, pin: pin, walletId: walletId)
        walletStore.addWallet(info)
        walletStore.setActiveWalletId(walletId)

        wallets = walletStore.loadWallets()
        activeWallet = info
        currentPin = pin
    }

    /// Legacy overload preserved for ChangePIN and the test suite.
    /// - When no active wallet exists, behaves like `addWallet` so single-
    ///   wallet flows (and the integration tests written against them)
    ///   continue to work unchanged.
    /// - When an active wallet exists, re-encrypts that wallet's seed
    ///   under the new PIN and optionally bumps its restore height.
    func saveWallet(mnemonic: [String], pin: String, restoreHeight: UInt64? = nil) throws {
        if activeWallet == nil {
            let name = walletStore.nextWalletName(existing: wallets)
            try addWallet(name: name, mnemonic: mnemonic, pin: pin, restoreHeight: restoreHeight)
            return
        }
        guard let active = activeWallet else { throw WalletError.saveFailed }
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin, walletId: active.id)
        currentPin = pin
        if let h = restoreHeight {
            updateRestoreHeight(h)
        }
    }

    func restoreWallet(name: String, emoji: String = "\u{1F4B0}", mnemonic: [String], pin: String, restoreDate: Date? = nil) throws {
        guard validateMnemonic(mnemonic) else {
            throw WalletError.invalidMnemonic
        }

        let seedPhrase = mnemonic.joined(separator: " ")

        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let candidateDerivedId = MoneroWallet.stableWalletId(for: seedPhrase + networkSuffix)
        try checkForDuplicateSeed(seedPhrase: seedPhrase, derivedId: candidateDerivedId, pin: pin)

        var height: UInt64 = 0
        if let date = restoreDate {
            height = UInt64(RestoreHeight.getHeight(date: date))
        }

        let walletId = UUID()
        let info = WalletInfo(
            id: walletId,
            name: name,
            emoji: emoji,
            source: .seeded(wordCount: mnemonic.count),
            createdAt: Date(),
            restoreHeight: height,
            syncResetCount: 0,
            userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: nil,
            cachedBalance: nil,
            derivedWalletId: candidateDerivedId
        )

        try keychain.saveSeed(seedPhrase, pin: pin, walletId: walletId)
        walletStore.addWallet(info)
        walletStore.setActiveWalletId(walletId)

        wallets = walletStore.loadWallets()
        activeWallet = info
        currentPin = pin
    }

    /// Legacy restoreWallet without name parameter (used by existing callers during transition)
    func restoreWallet(mnemonic: [String], pin: String, restoreDate: Date? = nil) throws {
        let name = walletStore.nextWalletName(existing: wallets)
        try restoreWallet(name: name, mnemonic: mnemonic, pin: pin, restoreDate: restoreDate)
    }

    /// Restore a view-only wallet from an address + private view key pair.
    /// Skips mnemonic validation (no seed) and checks for an address
    /// collision instead of a seed collision. Async so we can run a
    /// pre-flight wallet2 validation that proves the view key actually
    /// matches the address before persisting anything — wallet2's
    /// `generate_from_keys` compares `privViewKey * G` against the
    /// address's embedded public view key and throws on mismatch.
    func restoreViewOnlyWallet(
        name: String,
        emoji: String = "\u{1F441}",
        address: String,
        viewKey: String,
        pin: String,
        restoreDate: Date? = nil
    ) async throws {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedViewKey = viewKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard MoneroWallet.isValidAddress(trimmedAddress, networkType: networkType) else {
            throw WalletError.invalidMnemonic
        }
        // View keys are 64 lowercase hex characters
        let viewKeyRegex = try? NSRegularExpression(pattern: "^[0-9a-f]{64}$", options: [])
        let viewKeyRange = NSRange(location: 0, length: trimmedViewKey.utf16.count)
        guard viewKeyRegex?.firstMatch(in: trimmedViewKey, options: [], range: viewKeyRange) != nil else {
            throw WalletError.invalidMnemonic
        }

        // Reject if an existing wallet already tracks this address
        if let existing = wallets.first(where: { $0.cachedPrimaryAddress == trimmedAddress }) {
            throw WalletError.duplicateWallet(existingName: existing.name)
        }

        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let candidateDerivedId = MoneroWallet.stableWalletId(for: trimmedAddress + trimmedViewKey + networkSuffix)
        // Belt-and-braces collision check against a previously restored
        // view-only wallet that didn't have `cachedPrimaryAddress` populated.
        if let existing = wallets.first(where: { $0.derivedWalletId == candidateDerivedId }) {
            throw WalletError.duplicateWallet(existingName: existing.name)
        }

        // Pre-flight validation — open a throwaway wallet2 instance to prove
        // the view key matches the address. wallet2 throws here instead of
        // silently producing an empty wallet, which would mislead the user
        // into thinking their funds are gone. The files wallet2 writes are
        // keyed by the same stable ID the real unlock path will reuse, so
        // there's no garbage left on disk.
        let validator = MoneroWallet()
        do {
            try await validator.createWatchOnly(
                address: trimmedAddress,
                viewKey: trimmedViewKey,
                restoreHeight: 0,
                networkType: networkType
            )
        } catch {
            validator.stop()
            throw WalletError.invalidViewKey
        }
        validator.stop()

        var height: UInt64 = 0
        if let date = restoreDate {
            height = UInt64(RestoreHeight.getHeight(date: date))
        }

        let walletId = UUID()
        let info = WalletInfo(
            id: walletId,
            name: name,
            emoji: emoji,
            source: .viewOnly,
            createdAt: Date(),
            restoreHeight: height,
            syncResetCount: 0,
            userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: trimmedAddress,
            cachedBalance: nil,
            derivedWalletId: candidateDerivedId
        )

        try keychain.saveViewOnly(address: trimmedAddress, viewKey: trimmedViewKey, pin: pin, walletId: walletId)
        walletStore.addWallet(info)
        walletStore.setActiveWalletId(walletId)

        wallets = walletStore.loadWallets()
        activeWallet = info
        currentPin = pin
    }

    func validateMnemonic(_ mnemonic: [String]) -> Bool {
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
        // No fallback to the legacy global-keychain seed path: migration
        // runs in `checkForExistingWallet()` and produces a `WalletInfo`;
        // reaching here with `activeWallet == nil` means there is no
        // wallet on this device — surface invalidPin so the onboarding
        // flow takes over instead of silently unlocking legacy data.
        guard let active = activeWallet else {
            throw WalletError.invalidPin
        }

        currentPin = pin

        // Dispatch on the wallet's origin type. New wallet kinds (hardware)
        // slot in as additional cases; seed and view-only are live today.
        switch active.source {
        case .seed:
            let seedResult = try await Task.detached {
                try self.keychain.getSeed(pin: pin, walletId: active.id)
            }.value
            guard let seedPhrase = seedResult else {
                throw WalletError.invalidPin
            }
            let mnemonic = seedPhrase.split(separator: " ").map(String.init)
            currentSeed = mnemonic
            try await startWalletFromSeed(mnemonic)

            // Populate derivedWalletId lazily for wallets created before the
            // field existed, so future duplicate-seed checks catch them.
            populateDerivedWalletIdIfMissing(for: active.id, seedPhrase: seedPhrase)

        case .viewOnly:
            let viewKeys = try await Task.detached {
                try self.keychain.getViewOnly(pin: pin, walletId: active.id)
            }.value
            guard let keys = viewKeys else {
                throw WalletError.invalidPin
            }
            currentSeed = nil
            try await startWalletFromViewKey(address: keys.address, viewKey: keys.viewKey)

            populateDerivedWalletIdIfMissing(for: active.id, viewOnlyAddress: keys.address, viewKey: keys.viewKey)
        }
    }

    /// Fill in `derivedWalletId` on a legacy WalletInfo once we've unlocked
    /// its secret material. Idempotent — a no-op if already populated.
    private func populateDerivedWalletIdIfMissing(for walletId: UUID, seedPhrase: String) {
        guard var info = wallets.first(where: { $0.id == walletId }), info.derivedWalletId == nil else { return }
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        info.derivedWalletId = MoneroWallet.stableWalletId(for: seedPhrase + networkSuffix)
        walletStore.updateWallet(info)
        if let idx = wallets.firstIndex(where: { $0.id == walletId }) {
            wallets[idx] = info
        }
        if activeWallet?.id == walletId { activeWallet = info }
    }

    private func populateDerivedWalletIdIfMissing(for walletId: UUID, viewOnlyAddress: String, viewKey: String) {
        guard var info = wallets.first(where: { $0.id == walletId }), info.derivedWalletId == nil else { return }
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        info.derivedWalletId = MoneroWallet.stableWalletId(for: viewOnlyAddress + viewKey + networkSuffix)
        walletStore.updateWallet(info)
        if let idx = wallets.firstIndex(where: { $0.id == walletId }) {
            wallets[idx] = info
        }
        if activeWallet?.id == walletId { activeWallet = info }
    }

    /// Common wallet start logic used by unlock and switchToWallet
    private func startWalletFromSeed(_ mnemonic: [String]) async throws {
        // Tear down existing wallet if running (e.g. adding a wallet while unlocked)
        cancellables.removeAll()
        if let oldWallet = moneroWallet {
            moneroWallet = nil
            oldWallet.stop()
            // Give lifecycleQueue time to process the C++ close
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Intentionally skip @Published resets here: firing 7 back-to-back
        // mutations during a sheet-collapse transition races SwiftUI's
        // AttributeGraph teardown on iOS 26 and crashes (EXC_BAD_ACCESS in
        // AttributeInvalidatingSubscriber). The new wallet populates these
        // fields once it loads.
        //
        // syncState is also set to .connecting in `prepareSwitchToWallet`
        // (the synchronous Phase 1). `@Published` fires the publisher even
        // when the value hasn't changed, so re-assigning here would deliver
        // a notification 400ms into Phase 2 — exactly when the wallet
        // switcher sheet's AttributeGraph nodes are being torn down,
        // tripping the same crash. Guard with an equality check so the
        // publisher only fires when the state genuinely transitioned (i.e.
        // we entered through `unlock`, not `switchToWallet`).
        if syncState != .connecting {
            syncState = .connecting
        }

        let wallet = MoneroWallet()
        let walletRestoreHeight = activeWallet?.restoreHeight ?? 0
        let resetCount = activeWallet?.syncResetCount ?? 0
        let resetSuffix: String? = resetCount > 0 ? "\(resetCount)" : nil

        do {
            try await wallet.create(seed: mnemonic, restoreHeight: walletRestoreHeight, resetSuffix: resetSuffix, networkType: networkType)
        } catch {
            throw WalletError.invalidMnemonic
        }

        let runtimeAddress = wallet.primaryAddress
        if !runtimeAddress.isEmpty {
            self.primaryAddress = runtimeAddress
        }

        moneroWallet = wallet
        bindToWallet(wallet)

        loadUserCreatedSubaddresses()

        restoreHeight = walletRestoreHeight
        startConnectionTracking()

        isViewOnly = false
        isUnlocked = true
        walletSessionId = UUID()
    }

    /// Open a view-only wallet from a primary address + private view key.
    /// Mirrors `startWalletFromSeed` but routes through `MoneroWallet.createWatchOnly`.
    private func startWalletFromViewKey(address: String, viewKey: String) async throws {
        cancellables.removeAll()
        if let oldWallet = moneroWallet {
            moneroWallet = nil
            oldWallet.stop()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Same rationale as `startWalletFromSeed`: skip the batch of 7
        // @Published resets and only nudge `syncState` if it actually
        // changed, otherwise the redundant publisher fire races the
        // collapsing wallet-switcher sheet's AttributeGraph teardown.
        if syncState != .connecting {
            syncState = .connecting
        }

        let wallet = MoneroWallet()
        let walletRestoreHeight = activeWallet?.restoreHeight ?? 0

        do {
            try await wallet.createWatchOnly(
                address: address,
                viewKey: viewKey,
                restoreHeight: walletRestoreHeight,
                networkType: networkType
            )
        } catch {
            throw WalletError.saveFailed
        }

        // View-only wallets get their primary address directly from the user —
        // wallet2's runtime address may be empty until first refresh for certain
        // network configurations, so prefer the supplied address as a fallback.
        let runtimeAddress = wallet.primaryAddress
        self.primaryAddress = runtimeAddress.isEmpty ? address : runtimeAddress

        moneroWallet = wallet
        bindToWallet(wallet)

        loadUserCreatedSubaddresses()

        restoreHeight = walletRestoreHeight
        startConnectionTracking()

        isViewOnly = true
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

                #if DEBUG
                NSLog("[WalletManager] wallet2 syncState: %@ (current: %@)", "\(state)", "\(self.syncState)")
                #endif
                DiagnosticLog.shared.log("Sync: \(state)")

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

                // Debounce error states — wallet2 fires transient .notSynced
                // between refresh cycles that would cause UI to oscillate between
                // "Sync failed" and "Connecting". Only surface errors that persist.
                if case .error(let msg) = newState {
                    #if DEBUG
                    NSLog("[WalletManager] Error received, debouncing 3s: %@", msg)
                    #endif
                    DiagnosticLog.shared.log("wallet2 error: \(msg)")
                    self.errorDebounceTask?.cancel()
                    self.errorDebounceTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                        guard let self = self, !Task.isCancelled else { return }
                        #if DEBUG
                        NSLog("[WalletManager] Error persisted 3s, surfacing: %@", msg)
                        #endif
                        self.syncState = newState
                        self.updateConnectionStage()
                    }
                    return
                }

                // Non-error state arrived — cancel any pending error debounce
                if self.errorDebounceTask != nil {
                    #if DEBUG
                    NSLog("[WalletManager] Non-error state cancelled pending error debounce")
                    #endif
                }
                self.errorDebounceTask?.cancel()
                self.errorDebounceTask = nil

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

        // Track block heights for connection progress (throttled to reduce main thread churn)
        wallet.$daemonHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self else { return }
                let oldHeight = self.daemonHeight
                self.daemonHeight = height
                if oldHeight == 0 && height > 0 {
                    DiagnosticLog.shared.log("Daemon connected: height=\(height)")
                }
                let now = CACurrentMediaTime()
                guard now - self.lastHeightPublish >= 0.5 else { return }
                self.lastHeightPublish = now
                self.updateConnectionStage()
            }
            .store(in: &cancellables)

        wallet.$walletHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self else { return }
                self.walletHeight = height
                let now = CACurrentMediaTime()
                guard now - self.lastHeightPublish >= 0.5 else { return }
                self.lastHeightPublish = now
                self.updateConnectionStage()
            }
            .store(in: &cancellables)

        wallet.$transactions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTransactions in
                guard let self = self else { return }
                self.transactions = newTransactions
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

        // When the C++ library reports a different restore height (e.g. Polyseed birthday),
        // persist it so Settings and progress calculations use the correct value.
        wallet.$actualRestoreHeight
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self else { return }
                if height > 0 && height != self.restoreHeight {
                    #if DEBUG
                    NSLog("[WalletManager] Persisting C++ restore height: %llu (was %llu)", height, self.restoreHeight)
                    #endif
                    self.restoreHeight = height
                    self.updateRestoreHeight(height)
                }
            }
            .store(in: &cancellables)
    }

    func lock() {
        // Cache current wallet data before locking
        cacheActiveWalletData()

        // Cancel Combine subscriptions FIRST — they hold strong refs to the old wallet
        cancellables.removeAll()

        // Capture old wallet so its deallocation (Kit.deinit → C++ close)
        // happens off the main thread.
        let oldWallet = moneroWallet
        moneroWallet = nil
        Task.detached { [oldWallet] in let _ = oldWallet }

        currentSeed = nil
        currentPin = nil
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

    /// Cache balance and address into WalletInfo for switcher display
    private func cacheActiveWalletData() {
        guard var info = activeWallet else { return }
        info.cachedBalance = balance
        info.cachedPrimaryAddress = primaryAddress.isEmpty ? nil : primaryAddress
        info.userCreatedSubaddressIndices = Array(userCreatedSubaddressIndices)
        walletStore.updateWallet(info)
        activeWallet = info
        if let idx = wallets.firstIndex(where: { $0.id == info.id }) {
            wallets[idx] = info
        }
    }

    // MARK: - Connection Stage

    /// Update connection stage based on REAL detection, not timers
    /// Called when sync state, heights, or network status change
    private func updateConnectionStage() {
        let oldStage = connectionStage
        defer {
            if connectionStage != oldStage {
                DiagnosticLog.shared.log("Stage: \(oldStage) → \(connectionStage) (daemon=\(daemonHeight), wallet=\(walletHeight), nodeReachable=\(String(describing: nodeReachable)))")
                #if DEBUG
                NSLog("[WalletManager] connectionStage: %@ → %@", "\(oldStage)", "\(connectionStage)")
                #endif
            }
        }

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
        restoreHeight = activeWallet?.restoreHeight ?? 0

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
        DiagnosticLog.shared.log("Reachability check: \(nodeURLString)")
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
                    DiagnosticLog.shared.log("Node reachable: \(nodeURLString)")
                    // Run strict TLS check for diagnostics — tells us if wallet2 will have cert issues
                    self.runStrictTLSCheck(url: infoURL, nodeURLString: nodeURLString)
                    self.nodeReachable = true
                    self.reachabilityRetryCount = 0
                    self.reachabilityRetryTask?.cancel()
                    self.reachabilityRetryTask = nil
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let errMsg = error?.localizedDescription ?? "no error"
                    DiagnosticLog.shared.log("Node unreachable: \(nodeURLString) (HTTP \(code), \(errMsg))")
                    #if DEBUG
                    NSLog("[WalletManager] Node unreachable: %@ (HTTP %d)", nodeURLString, code)
                    #endif
                    self.nodeReachable = false
                }
                self.updateConnectionStage()
            }
        }
        currentReachabilityTask = task
        task.resume()
    }

    /// Diagnostic-only: test the node with standard TLS validation (no cert bypass).
    /// If this fails, wallet2 C++ will likely fail too since it uses its own OpenSSL.
    private func runStrictTLSCheck(url: URL, nodeURLString: String) {
        guard nodeURLString.hasPrefix("https") else { return } // Only relevant for HTTPS nodes

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        strictTLSSession.dataTask(with: request) { data, response, error in
            if let error = error {
                DiagnosticLog.shared.log("TLS STRICT FAILED: \(nodeURLString) — \(error.localizedDescription)")
                DiagnosticLog.shared.log("⚠ Node cert may be invalid — wallet2 C++ will likely also fail")
            } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                DiagnosticLog.shared.log("TLS strict: OK (\(nodeURLString))")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DiagnosticLog.shared.log("TLS strict: HTTP \(code) (\(nodeURLString))")
            }
        }.resume()
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

    /// Save current wallet data for home screen widget.
    /// Captures state on main, then does all formatting/IO on a background queue.
    func saveWidgetData(enabled: Bool? = nil) {
        // Snapshot only — fast reads, then immediately hand off
        let isEnabled = enabled ?? UserDefaults.standard.bool(forKey: "widgetEnabled")
        let snapBalance = balance
        let snapSyncState = syncState
        let snapTransactions = Array(transactions.prefix(5))
        let snapIsTestnet = isTestnet

        DispatchQueue.global(qos: .utility).async {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 4
            formatter.maximumFractionDigits = 4

            let balanceFormatted = formatter.string(from: snapBalance as NSDecimalNumber) ?? "0.0000"

            let widgetSyncStatus: WidgetData.SyncStatus
            switch snapSyncState {
            case .synced: widgetSyncStatus = .synced
            case .syncing: widgetSyncStatus = .syncing
            case .connecting: widgetSyncStatus = .connecting
            case .idle, .error: widgetSyncStatus = .offline
            }

            let recentTransactions = snapTransactions.map { tx in
                WidgetTransaction(
                    id: tx.id,
                    isIncoming: tx.type == .incoming,
                    amount: tx.amount,
                    amountFormatted: formatter.string(from: tx.amount as NSDecimalNumber) ?? "0.0000",
                    timestamp: tx.timestamp,
                    isConfirmed: (tx.confirmations ?? 0) >= 10
                )
            }

            var widgetData = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
            widgetData.balance = snapBalance
            widgetData.balanceFormatted = balanceFormatted
            widgetData.syncStatus = widgetSyncStatus
            widgetData.lastUpdated = Date()
            widgetData.recentTransactions = recentTransactions
            widgetData.isTestnet = snapIsTestnet
            widgetData.isEnabled = isEnabled

            WidgetDataManager.shared.save(widgetData)
        }
    }

    /// Save widget data if widget is enabled - called during sync cycles
    /// Debounced: batches rapid updates into a single save + reload after 1 second
    private func saveWidgetDataIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "widgetEnabled") else { return }

        // Debounce: cancel any pending save and schedule a new one.
        // Run ENTIRELY off main — saveWidgetData does formatting, fiat conversion,
        // and file I/O that can block main for 100s of ms on device.
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
        if isViewOnly { throw WalletError.viewOnlyCannotSend }
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.estimateFee(to: address, amount: amount)
    }

    func send(to address: String, amount: Decimal, memo: String? = nil) async throws -> String {
        if isViewOnly { throw WalletError.viewOnlyCannotSend }
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.send(to: address, amount: amount, memo: memo)
    }

    func sendAll(to address: String, memo: String? = nil) async throws -> String {
        if isViewOnly { throw WalletError.viewOnlyCannotSend }
        guard let wallet = moneroWallet else {
            throw WalletError.notUnlocked
        }
        return try await wallet.sendAll(to: address, memo: memo)
    }

    // MARK: - Seed Export

    /// Returns the legacy 25-word seed from the running wallet.
    func getLegacySeed() -> [String]? {
        moneroWallet?.getLegacySeed()
    }

    /// Returns the polyseed (16 words) if wallet was created with one.
    func getPolyseed() -> [String]? {
        moneroWallet?.getPolyseed()
    }

    /// Detected seed type for the current wallet
    var detectedSeedType: SeedType? {
        guard let seed = currentSeed else { return nil }
        return SeedType.detect(from: seed.count)
    }

    // MARK: - Subaddresses

    /// Create a new subaddress for receiving payments
    /// - Returns: The newly created SubAddress, or nil if creation failed
    func createSubaddress() async -> MoneroKit.SubAddress? {
        guard let wallet = moneroWallet else { return nil }
        let result = wallet.createSubaddress()
        if let newSubaddr = result {
            userCreatedSubaddressIndices.insert(newSubaddr.index)
            saveUserCreatedSubaddresses()
            return newSubaddr
        }
        return nil
    }

    /// Rename a subaddress. Label is persisted via wallet2's `.keys` cache on disk.
    @discardableResult
    func setSubaddressLabel(index: Int, label: String) -> Bool {
        guard let wallet = moneroWallet else { return false }
        return wallet.setSubaddressLabel(index: index, label: label)
    }

    // MARK: - User-Created Subaddress Persistence

    private func saveUserCreatedSubaddresses() {
        guard var info = activeWallet else { return }
        info.userCreatedSubaddressIndices = Array(userCreatedSubaddressIndices)
        walletStore.updateWallet(info)
        activeWallet = info
    }

    private func loadUserCreatedSubaddresses() {
        let saved = activeWallet?.userCreatedSubaddressIndices ?? []
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

        // If wallet2 is in an error state, a simple refresh won't recover —
        // the C++ connection is dead. Do a full restart instead.
        if case .error = syncState, let seed = currentSeed {
            #if DEBUG
            NSLog("[WalletManager] refresh(): wallet in error state, doing full restart")
            #endif
            restartWallet(with: seed)
            return
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
        NodeCredentialStore.save(login: login, password: password, isTestnet: isTestnet)

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

        let nodeURL = UserDefaults.standard.string(forKey: isTestnet ? "selectedTestnetNodeURL" : "selectedNodeURL") ?? "default"
        DiagnosticLog.shared.log("Restarting wallet with node: \(nodeURL)")
        syncState = .connecting

        // Cancel any in-flight restart
        restartTask?.cancel()

        let oldWallet = moneroWallet
        moneroWallet = nil
        cancellables.removeAll()

        let walletRestoreHeight = activeWallet?.restoreHeight ?? 0
        let resetCount = activeWallet?.syncResetCount ?? 0
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
        guard let active = activeWallet else { return nil }
        return try getSeedPhrase(pin: pin, expectedWalletId: active.id)
    }

    /// Seed export gated on the caller's expected wallet identity. Export
    /// screens capture the active wallet's ID at `.onAppear` and pass it
    /// here so a mid-view wallet swap is rejected rather than silently
    /// returning the new wallet's seed. `walletMismatch` is distinct from
    /// `invalidPin` so the UI can tell the user the wallet changed.
    func getSeedPhrase(pin: String, expectedWalletId: UUID) throws -> [String]? {
        guard let active = activeWallet else { return nil }
        guard active.id == expectedWalletId else {
            throw WalletError.walletMismatch
        }
        guard let seedPhrase = try keychain.getSeed(pin: pin, walletId: expectedWalletId) else {
            return nil
        }
        let mnemonic = seedPhrase.split(separator: " ").map(String.init)

        // CRITICAL: Verify seed matches the currently unlocked wallet
        if !primaryAddress.isEmpty, let currentSeedMnemonic = currentSeed {
            if mnemonic != currentSeedMnemonic {
                #if DEBUG
                NSLog("[WalletManager] CRITICAL: Keychain seed doesn't match unlocked wallet seed!")
                #endif
                throw WalletError.seedMismatch
            }
        }

        return mnemonic
    }

    /// Fetch the address + private view key for a view-only wallet. Used by
    /// the Backup screen to export the same pair the user originally pasted.
    func getViewOnlyKeys(pin: String) throws -> (address: String, viewKey: String)? {
        guard let active = activeWallet else { return nil }
        return try keychain.getViewOnly(pin: pin, walletId: active.id)
    }

    /// The live wallet's private view key (64 hex chars). Works for both
    /// seeded and view-only wallets so any wallet can be exported to
    /// another device as view-only.
    var currentViewKey: String? {
        moneroWallet?.secretViewKey
    }

    /// Atomic snapshot of everything the view-key export screen needs,
    /// gated on the caller's expected wallet ID. Returns nil if the
    /// active wallet changed underneath the caller — callers should
    /// treat nil as "dismiss the export sheet". Pulling all four fields
    /// inside a single guard prevents a mid-switch race from producing
    /// a share payload with wallet A's address and wallet B's view key.
    func exportViewKeyData(expectedWalletId: UUID) -> (address: String, viewKey: String, restoreHeight: UInt64)? {
        guard let active = activeWallet, active.id == expectedWalletId else { return nil }
        guard let wallet = moneroWallet else { return nil }
        let snapshotAddress = primaryAddress
        guard let snapshotViewKey = wallet.secretViewKey, !snapshotViewKey.isEmpty else { return nil }
        let snapshotHeight = restoreHeight
        // Re-verify after the reads: if `activeWallet` moved between the
        // first guard and the last field read, we must discard the tuple.
        guard activeWallet?.id == expectedWalletId else { return nil }
        return (snapshotAddress, snapshotViewKey, snapshotHeight)
    }

    /// Expose current PIN for adding wallets (only available while unlocked)
    var currentPinForAddWallet: String? {
        currentPin
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
        guard let seed = currentSeed, var info = activeWallet else {
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

        // Increment reset counter via WalletStore
        info.syncResetCount += 1
        walletStore.updateWallet(info)
        activeWallet = info
        if let idx = wallets.firstIndex(where: { $0.id == info.id }) {
            wallets[idx] = info
        }

        let walletRestoreHeight = info.restoreHeight
        let resetSuffix = "\(info.syncResetCount)"
        let netType = networkType

        // Create new wallet — Kit init runs off main via async create()
        Task {
            do {
                let wallet = MoneroWallet()
                try await wallet.create(seed: seed, restoreHeight: walletRestoreHeight, resetSuffix: resetSuffix, networkType: netType)
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
        guard let active = activeWallet else { return }
        deleteWallet(id: active.id)
    }

    /// Wipes every wallet on this device. After this returns, `wallets` is empty
    /// and `ContentView` will route to onboarding.
    func deleteAllWallets() {
        // Tear down active wallet first so deleteWallet(id:) doesn't auto-switch.
        let ids = wallets.map { $0.id }
        for id in ids {
            deleteWallet(id: id)
        }
    }

    func deleteWallet(id: UUID) {
        let isDeletingActive = (id == activeWallet?.id)

        // Delete keychain data for this wallet — both seed and view-only slots;
        // deleteSeed wipes shared pinhash/salt as well.
        keychain.deleteViewOnly(walletId: id)
        keychain.deleteSeed(walletId: id)
        walletStore.removeWallet(id: id)
        wallets = walletStore.loadWallets()

        if isDeletingActive {
            // Stop current wallet
            cancellables.removeAll()
            errorDebounceTask?.cancel()
            errorDebounceTask = nil
            currentReachabilityTask?.cancel()
            currentReachabilityTask = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
            reachabilityRetryCount = 0
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
            userCreatedSubaddressIndices = []

            if let next = wallets.first {
                // Switch to next wallet
                activeWallet = next
                walletStore.setActiveWalletId(next.id)

                // If we have the PIN, auto-switch
                if let pin = currentPin {
                    Task {
                        try? await switchToWallet(id: next.id, pin: pin)
                    }
                }
            } else {
                activeWallet = nil
                currentPin = nil
                walletStore.setActiveWalletId(nil)
            }
        }
    }

    // MARK: - Network Switching

    // MARK: - Multi-Wallet

    /// Phase 1: Instant UI update (synchronous, no await).
    /// Returns (target, previousWalletInfo) if the switch should proceed, nil otherwise.
    func prepareSwitchToWallet(id: UUID) -> (target: WalletInfo, previous: WalletInfo?)? {
        guard let target = wallets.first(where: { $0.id == id }) else { return nil }
        guard target.id != activeWallet?.id else { return nil }

        // Snapshot previous wallet data in-memory only (no disk I/O)
        var previousInfo: WalletInfo?
        if var info = activeWallet {
            info.cachedBalance = balance
            info.cachedPrimaryAddress = primaryAddress.isEmpty ? nil : primaryAddress
            info.userCreatedSubaddressIndices = Array(userCreatedSubaddressIndices)
            previousInfo = info
            activeWallet = info
            if let idx = wallets.firstIndex(where: { $0.id == info.id }) {
                wallets[idx] = info
            }
        }

        // Set new active wallet immediately — UI sees the change NOW
        activeWallet = target
        walletStore.setActiveWalletId(target.id)

        // Show cached data instantly
        balance = target.cachedBalance ?? 0
        primaryAddress = target.cachedPrimaryAddress ?? ""
        address = target.cachedPrimaryAddress ?? ""
        syncState = .connecting
        currentSeed = nil
        connectionStage = .connecting
        daemonHeight = 0
        walletHeight = 0
        restoreHeight = target.restoreHeight
        walletSessionId = UUID()
        transactions = []
        subaddresses = []
        userCreatedSubaddressIndices = []

        return (target, previousInfo)
    }

    /// Phase 2: Heavy work (async, runs in background after UI has updated).
    func completeSwitchToWallet(target: WalletInfo, persistPrevious: WalletInfo? = nil) async throws {
        // Persist previous wallet's cached data to disk (off the animation hot path)
        if let previous = persistPrevious {
            walletStore.updateWallet(previous)
        }

        // Let the collapse animation finish before tearing down the old wallet
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4s — just past the 0.35s animation

        // Tear down old wallet
        cancellables.removeAll()
        let oldWallet = moneroWallet
        moneroWallet = nil
        oldWallet?.stop()

        guard let pin = currentPin else { throw WalletError.notUnlocked }

        // Route by wallet source. View-only wallets have no seed on-device, so
        // they can't be started via `startWalletFromSeed` — the previous
        // unconditional `getSeed` path returned nil for them and the error was
        // silently swallowed by the `try?` at the switcher call site, leaving
        // the UI stuck at "connecting" with no wallet running.
        switch target.source {
        case .seed:
            guard let seedPhrase = try keychain.getSeed(pin: pin, walletId: target.id) else {
                throw WalletError.invalidPin
            }
            let mnemonic = seedPhrase.split(separator: " ").map(String.init)
            currentSeed = mnemonic
            try await startWalletFromSeed(mnemonic)

        case .viewOnly:
            guard let keys = try keychain.getViewOnly(pin: pin, walletId: target.id) else {
                throw WalletError.invalidPin
            }
            currentSeed = nil
            try await startWalletFromViewKey(address: keys.address, viewKey: keys.viewKey)
        }
    }

    /// Switch to a different wallet. Requires the app to be unlocked (currentPin available).
    func switchToWallet(id: UUID) async throws {
        guard let pin = currentPin else {
            throw WalletError.notUnlocked
        }
        try await switchToWallet(id: id, pin: pin)
    }

    /// Switch to a different wallet with explicit PIN (convenience that calls both phases sequentially)
    func switchToWallet(id: UUID, pin: String) async throws {
        guard let result = prepareSwitchToWallet(id: id) else { return }
        try await completeSwitchToWallet(target: result.target, persistPrevious: result.previous)
    }

    /// Rename a wallet (and optionally change its emoji)
    func renameWallet(id: UUID, name: String, emoji: String? = nil) {
        guard var info = wallets.first(where: { $0.id == id }) else { return }
        info.name = name
        if let emoji { info.emoji = emoji }
        walletStore.updateWallet(info)
        if let idx = wallets.firstIndex(where: { $0.id == id }) {
            wallets[idx] = info
        }
        if activeWallet?.id == id {
            activeWallet = info
        }
    }

    /// Re-encrypt every wallet's secret material when PIN changes. Walks
    /// wallets by `source` so view-only wallets (which have no seed) are
    /// re-encrypted through their view-key slot — the previous
    /// seed-only loop hit `invalidPin` on view-only entries and aborted
    /// the whole PIN change, leaving mixed installs unable to rotate.
    func reencryptAllWallets(oldPin: String, newPin: String) throws {
        var seeds: [(UUID, String)] = []
        var viewOnlyKeys: [(UUID, String, String)] = []
        for wallet in wallets {
            switch wallet.source {
            case .seed:
                guard let seed = try keychain.getSeed(pin: oldPin, walletId: wallet.id) else {
                    throw WalletError.invalidPin
                }
                seeds.append((wallet.id, seed))
            case .viewOnly:
                guard let keys = try keychain.getViewOnly(pin: oldPin, walletId: wallet.id) else {
                    throw WalletError.invalidPin
                }
                viewOnlyKeys.append((wallet.id, keys.address, keys.viewKey))
            }
        }

        for (walletId, seed) in seeds {
            try keychain.saveSeed(seed, pin: newPin, walletId: walletId)
        }
        for (walletId, address, viewKey) in viewOnlyKeys {
            try keychain.saveViewOnly(address: address, viewKey: viewKey, pin: newPin, walletId: walletId)
        }

        currentPin = newPin
    }

    /// Convenience that derives the ID internally — use when the caller
    /// only has the seed string on hand (e.g. pre-restore UI checks).
    func checkForDuplicateSeed(seedPhrase: String, pin: String) throws {
        let networkSuffix = networkType == .testnet ? "_testnet" : ""
        let derivedId = MoneroWallet.stableWalletId(for: seedPhrase + networkSuffix)
        try checkForDuplicateSeed(seedPhrase: seedPhrase, derivedId: derivedId, pin: pin)
    }

    /// Reject a seed that matches one already on-device. Primary check is
    /// the derived wallet ID (SHA-256 of seed+network) — needs no PIN and
    /// catches duplicates regardless of which PIN each wallet was saved
    /// under. The PIN-gated seed comparison is kept as a fallback for
    /// wallets created before `derivedWalletId` existed.
    func checkForDuplicateSeed(seedPhrase: String, derivedId: String, pin: String) throws {
        for wallet in wallets {
            if let storedId = wallet.derivedWalletId, storedId == derivedId {
                throw WalletError.duplicateWallet(existingName: wallet.name)
            }
        }
        // Fallback: only hits legacy wallets whose derivedWalletId is nil.
        for wallet in wallets where wallet.derivedWalletId == nil {
            if let existingSeed = try? keychain.getSeed(pin: pin, walletId: wallet.id),
               existingSeed == seedPhrase {
                throw WalletError.duplicateWallet(existingName: wallet.name)
            }
        }
    }

    /// Update restore height for the active wallet and persist
    func updateRestoreHeight(_ height: UInt64) {
        guard var info = activeWallet else { return }
        info.restoreHeight = height
        walletStore.updateWallet(info)
        activeWallet = info
        if let idx = wallets.firstIndex(where: { $0.id == info.id }) {
            wallets[idx] = info
        }
        restoreHeight = height
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

        let walletRestoreHeight = activeWallet?.restoreHeight ?? 0
        let resetCount = activeWallet?.syncResetCount ?? 0
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

enum WalletError: LocalizedError, Equatable {
    case invalidMnemonic
    case invalidPin
    case saveFailed
    case notUnlocked
    case biometricFailed
    case seedMismatch
    case duplicateWallet(existingName: String)
    case invalidViewKey
    case walletMismatch
    case viewOnlyCannotSend

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic: return "Invalid seed phrase"
        case .invalidPin: return "Invalid PIN"
        case .saveFailed: return "Failed to save wallet"
        case .notUnlocked: return "Wallet is locked"
        case .biometricFailed: return "Biometric authentication failed"
        case .seedMismatch: return "Seed phrase doesn't match current wallet"
        case .duplicateWallet(let name): return "This seed phrase is already used by \"\(name)\""
        case .invalidViewKey: return "View key doesn't match this address"
        case .walletMismatch: return "Active wallet changed — please retry"
        case .viewOnlyCannotSend: return "View-only wallets cannot send transactions"
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
            let creds = NodeCredentialStore.load(isTestnet: isTestnet)
            let login = creds.login
            let password = creds.password
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
