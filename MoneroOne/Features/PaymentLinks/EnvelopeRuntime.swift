import Foundation
import Combine
import UIKit
import MoneroKit

/// Runs envelope wallets. MoneroKit runs one wallet at a time, so while a
/// payment-link screen needs an envelope, the active wallet is stopped and
/// the envelope wallet runs in its place; the active wallet starts again
/// when the last such screen goes away.
///
/// One envelope is open at a time. Its files live in
/// `Application Support/MoneroKit/envelopes/<id>/`: outside the 32-hex names
/// the launch cache sweep deletes, and excluded from backup. They are deleted
/// when the envelope settles.
@MainActor
final class EnvelopeRuntime: ObservableObject {
    static let shared = EnvelopeRuntime()

    /// Where a claim or reclaim sends the money: the active wallet's current
    /// receive address (the one Receive shows), read before the wallet stops.
    struct Destination: Equatable {
        let address: String
        let walletName: String
    }

    enum RuntimeError: LocalizedError, Equatable {
        case walletBusy
        case noDestination
        case nodeUnreachable(String)
        case syncTimedOut
        case addressMismatch
        case alreadyClaimed
        case sweepFailed(String)
        case nothingToSweep

        var errorDescription: String? {
            switch self {
            case .walletBusy:
                return String(localized: "Your wallet is busy. Try again in a moment.")
            case .noDestination:
                return String(localized: "Your wallet has no receive address yet. Wait for it to load, then try again.")
            case .nodeUnreachable(let detail):
                return detail.isEmpty
                    ? String(localized: "Could not reach the node. Check your connection and try again.")
                    : String(localized: "Could not reach the node: \(detail)")
            case .syncTimedOut:
                return String(localized: "Checking the link took too long. Try again.")
            case .addressMismatch:
                return String(localized: "This link failed its safety check. Do not use it.")
            case .alreadyClaimed:
                return String(localized: "Already claimed.")
            case .sweepFailed(let detail):
                return detail
            case .nothingToSweep:
                return String(localized: "This link holds no money that can move yet.")
            }
        }
    }

    @Published private(set) var openEnvelopeId: String?
    /// Sync progress of the open envelope, 0...1, while it syncs.
    @Published private(set) var syncProgress: Double?
    @Published private(set) var destination: Destination?

    private weak var walletManager: WalletManager?
    private var envelope: MoneroWallet?
    private var leases = 0
    private var mainSuspended = false
    private var resumeTask: Task<Void, Never>?
    /// The active wallet starting again; a new lease waits for it, so the
    /// envelope never starts while the main wallet is half up.
    private var resumeInFlight: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    /// Bumped when every screen let go of the runtime or the app locked. A
    /// scan from an older generation stops at once, so a long envelope scan
    /// never keeps the active wallet stopped.
    private var generation = 0
    private var observers = Set<AnyCancellable>()
    private var lockObserver: AnyCancellable?

    private init() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.pauseForBackground() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.envelope?.startSync() }
            .store(in: &observers)
    }

    // MARK: - Leases

    /// A payment-link screen needs envelope wallets. The first lease stops
    /// the active wallet; it reads the claim destination before it does.
    func acquire(_ walletManager: WalletManager) async throws {
        leases += 1
        resumeTask?.cancel()
        resumeTask = nil
        await resumeInFlight?.value
        guard !mainSuspended else { return }
        self.walletManager = walletManager
        guard let address = Self.receiveAddress(of: walletManager) else {
            leases -= 1
            throw RuntimeError.noDestination
        }
        destination = Destination(address: address, walletName: walletManager.activeWallet?.name ?? "")
        guard await walletManager.suspendActiveWalletForEnvelope() else {
            leases -= 1
            destination = nil
            throw RuntimeError.walletBusy
        }
        mainSuspended = true
        watchLock(walletManager)
    }

    /// The screen is done. When no lease is left, the envelope closes and
    /// the active wallet starts again (after a short delay, so moving from
    /// the list to a detail does not restart it in between).
    func release() {
        leases = max(0, leases - 1)
        guard leases == 0, mainSuspended else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.leases == 0 else { return }
            self.generation += 1
            let resume = Task { @MainActor in await self.resumeMain() }
            self.resumeInFlight = resume
            await resume.value
            self.resumeInFlight = nil
        }
    }

    private func resumeMain() async {
        await closeEnvelope()
        guard mainSuspended else { return }
        mainSuspended = false
        destination = nil
        do {
            try await walletManager?.resumeActiveWalletAfterEnvelope()
        } catch {
            // Never show an unlocked app with no wallet running: lock, and
            // the PIN starts the wallet through the normal unlock.
            DiagnosticLog.shared.log("Envelope: active wallet did not restart: \(error.localizedDescription)")
            walletManager?.lock()
        }
    }

    /// A lock tears every payment-link screen down; the wallet starts again
    /// after the PIN through the normal unlock.
    private func watchLock(_ walletManager: WalletManager) {
        lockObserver = walletManager.$isUnlocked
            .removeDuplicates()
            .filter { !$0 }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.resumeTask?.cancel()
                    self.generation += 1
                    self.leases = 0
                    self.mainSuspended = false
                    self.destination = nil
                    await self.closeEnvelope()
                }
            }
    }

    // MARK: - Envelope

    /// Opens the envelope of `link` (closing any other) and syncs it to the
    /// chain tip. Checks that the running wallet's address is `address`.
    func check(link: EnvelopeLink, address: String) async throws -> EnvelopeObservation {
        try await serial { [self] in
            guard let walletManager, mainSuspended else { throw RuntimeError.walletBusy }
            if openEnvelopeId != link.id {
                await closeEnvelopeNow()
                let wallet = MoneroWallet()
                syncProgress = 0
                Self.excludeEnvelopesFromBackup()
                try await wallet.create(
                    seed: link.words,
                    restoreHeight: link.restoreHeight,
                    networkType: walletManager.networkType,
                    cacheIdOverride: Self.cacheId(for: link.id)
                )
                envelope = wallet
                openEnvelopeId = link.id
            } else {
                envelope?.startSync()
            }
            guard let wallet = envelope else { throw RuntimeError.walletBusy }
            // A cached envelope reports synced at its old height before its
            // first refresh: wait for the chain tip the main wallet last saw.
            try await waitUntilSynced(wallet, atLeast: walletManager.daemonHeight)
            syncProgress = nil
            let runtimeAddress = wallet.primaryAddress
            if !runtimeAddress.isEmpty, runtimeAddress != address {
                throw RuntimeError.addressMismatch
            }
            let observation = await observe(wallet)
            DiagnosticLog.shared.log("Envelope check: height \(wallet.walletHeight)/\(wallet.daemonHeight), funded \(observation.fundingSeen), spends \(observation.spendTxids.count), balance \(observation.balance > 0 ? "yes" : "none")")
            return observation
        }
    }

    /// Looks for new blocks on the open envelope and returns what it sees.
    func poll() async throws -> EnvelopeObservation? {
        try await serial { [self] in
            guard let wallet = envelope else { return nil }
            wallet.startSync()
            try await Task.sleep(for: .seconds(2))
            try await waitUntilSynced(wallet)
            return await observe(wallet)
        }
    }

    /// Sweeps every unlocked piconero of the open envelope to `address`.
    /// The fee comes out of the envelope.
    func sweep(to address: String) async throws -> (txid: String, amount: UInt64) {
        try await serial { [self] in
            guard let wallet = envelope else { throw RuntimeError.walletBusy }
            guard wallet.unlockedBalance > 0 else { throw RuntimeError.nothingToSweep }
            do {
                let txid = try await wallet.sendAll(to: address, memo: nil)
                let txs = await wallet.fetchTransactionsBlocking()
                let tx = txs.first { $0.id == txid }
                let sent = tx.map { tx in
                    tx.destinations.isEmpty ? abs(tx.amount) : tx.destinations.reduce(Decimal(0)) { $0 + $1.amount }
                } ?? 0
                return (txid, Self.piconero(sent))
            } catch {
                throw Self.mapSweepError(error)
            }
        }
    }

    /// Closes the open envelope wallet (files stay).
    func closeEnvelope() async {
        _ = try? await serial { [self] in await closeEnvelopeNow() }
    }

    /// Remove All: stops any scan and deletes every envelope's files (only
    /// `MoneroKit/envelopes`, never the wallets' caches).
    func wipeAll() async {
        generation += 1
        _ = try? await serial { [self] in
            await closeEnvelopeNow()
            guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MoneroKit/envelopes", isDirectory: true) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Deletes the envelope's files. Closes it first when it is open.
    func deleteFiles(id: String) async {
        _ = try? await serial { [self] in
            if openEnvelopeId == id { await closeEnvelopeNow() }
            guard EnvelopeLink.isEnvelopeId(id), let dir = Self.directory(for: id) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private func closeEnvelopeNow() async {
        guard let wallet = envelope else { return }
        envelope = nil
        openEnvelopeId = nil
        syncProgress = nil
        await wallet.stopAsync()
    }

    private func observe(_ wallet: MoneroWallet) async -> EnvelopeObservation {
        // The kit refreshes balance and history right after it reports
        // synced; give that a moment, then read history directly.
        try? await Task.sleep(for: .milliseconds(1500))
        let txs = await wallet.fetchTransactionsBlocking()
        return Self.observation(transactions: txs, balance: wallet.balance, unlocked: wallet.unlockedBalance, daemonHeight: wallet.daemonHeight)
    }

    nonisolated static func observation(transactions: [MoneroTransaction], balance: Decimal, unlocked: Decimal, daemonHeight: UInt64) -> EnvelopeObservation {
        let live = transactions.filter { $0.status != .failed }
        let incoming = live.filter { $0.type == .incoming }
        let confirmations = incoming.map { tx -> Int in
            guard tx.status == .confirmed, let height = tx.blockHeight, daemonHeight > height else { return 0 }
            return Int(daemonHeight - height)
        }.max() ?? 0
        // A reopened kit starts from a zero balance and stores a new one only
        // when it changes, so an envelope emptied since its last open keeps
        // its old stored balance. The history is fresh: never report more
        // than it leaves.
        let outgoing = live.filter { $0.type == .outgoing }
        let received = incoming.reduce(Decimal(0)) { $0 + $1.amount }
        let spent = outgoing.reduce(Decimal(0)) { $0 + $1.amount + $1.fee }
        let balance = min(balance, max(0, received - spent))
        let unlocked = min(unlocked, balance)
        let fundingHeight = incoming.compactMap { $0.status == .confirmed ? $0.blockHeight : nil }.min()
        return EnvelopeObservation(
            fundingSeen: !incoming.isEmpty,
            fundingConfirmations: confirmations,
            balance: piconero(balance),
            unlockedBalance: piconero(unlocked),
            spendTxids: outgoing.map(\.id),
            fundingHeight: fundingHeight
        )
    }

    private func waitUntilSynced(_ wallet: MoneroWallet, atLeast tip: UInt64 = 0) async throws {
        var lastHeight: UInt64 = 0
        var lastProgress = Date()
        let started = generation
        while true {
            try Task.checkCancellation()
            if generation != started { throw CancellationError() }
            switch wallet.syncState {
            case .synced where wallet.daemonHeight > 0 && wallet.daemonHeight >= tip:
                return
            case .error(let message):
                throw RuntimeError.nodeUnreachable(message)
            case .syncing(let progress, _):
                syncProgress = progress / 100
            default:
                break
            }
            if wallet.walletHeight != lastHeight {
                lastHeight = wallet.walletHeight
                lastProgress = Date()
            }
            // No new block scanned for a minute: the node is gone.
            if Date().timeIntervalSince(lastProgress) > 60 {
                throw RuntimeError.syncTimedOut
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func pauseForBackground() {
        guard let wallet = envelope else { return }
        let app = UIApplication.shared
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = app.beginBackgroundTask(withName: "PauseEnvelopeSync") {
            app.endBackgroundTask(taskId)
            taskId = .invalid
        }
        Task {
            await wallet.pauseSyncAsync()
            if taskId != .invalid { app.endBackgroundTask(taskId) }
        }
    }

    /// Runs `body` after every earlier runtime operation finished, so two
    /// screens never open or sweep envelopes at the same time.
    private func serial<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        chain = Task { _ = await task.value }
        return try await task.value.get()
    }

    nonisolated static func cacheId(for id: String) -> String { "envelopes/\(id)" }

    nonisolated static func directory(for id: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoneroKit", isDirectory: true)
            .appendingPathComponent(cacheId(for: id), isDirectory: true)
    }

    nonisolated private static func excludeEnvelopesFromBackup() {
        guard var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoneroKit/envelopes", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The address Receive shows for the active wallet.
    static func receiveAddress(of walletManager: WalletManager) -> String? {
        let index = walletManager.selectedReceiveIndex
        if index != 0,
           let sub = walletManager.subaddresses.first(where: { $0.index == index }),
           !sub.address.isEmpty, !NullKeyAddress.isNullKey(sub.address) {
            return sub.address
        }
        let primary = walletManager.primaryAddress
        guard !primary.isEmpty, !NullKeyAddress.isNullKey(primary), walletManager.isValidAddress(primary) else { return nil }
        return primary
    }

    nonisolated static func piconero(_ xmr: Decimal) -> UInt64 {
        let value = xmr * Decimal(1_000_000_000_000)
        guard value > 0 else { return 0 }
        return NSDecimalNumber(decimal: value).uint64Value
    }

    nonisolated static func xmr(_ piconero: UInt64) -> Decimal {
        Decimal(piconero) / Decimal(1_000_000_000_000)
    }

    private static func mapSweepError(_ error: Error) -> Error {
        let text = String(describing: error).lowercased()
        // Only the daemon's double-spend verdict means someone else swept
        // first; any other failure keeps the link claimable.
        if text.contains("double spend") || text.contains("double_spend") {
            return RuntimeError.alreadyClaimed
        }
        if let core = error as? MoneroCoreError {
            switch core {
            case .transactionSendFailed(let msg), .transactionEstimationFailed(let msg):
                return RuntimeError.sweepFailed(msg)
            case .transactionCommitFailed(let msg):
                return RuntimeError.sweepFailed(String(localized: "Broadcast failed: \(msg)"))
            default:
                break
            }
        }
        return RuntimeError.sweepFailed(error.localizedDescription)
    }
}
