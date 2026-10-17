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

    /// The active wallet's main address (the one the wallet switcher shows),
    /// read before the wallet stops. A claim or reclaim goes here unless the
    /// user picks another wallet (`PaymentLinkClaimDestinations`).
    struct Destination: Equatable {
        let address: String
        let walletName: String
        var walletId: UUID? = nil
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
    /// Envelopes scanned again this run because they missed a mined
    /// funding; that rescan runs once per run.
    private var rescannedIds = Set<String>()
    /// The open envelope's scan starts at this height.
    private var openScanFrom: UInt64?
    /// When the open envelope's first refresh reached `openScanFrom`. A
    /// save after this time holds a scanned wallet, so the close records
    /// the scan start on disk (see `closeEnvelopeNow`).
    private var openScanRefreshedAt: Date?
    /// "Link 7", for the diagnostic log.
    private var openName: String?
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
        guard let address = Self.mainAddress(of: walletManager) else {
            leases -= 1
            throw RuntimeError.noDestination
        }
        destination = Destination(address: address, walletName: walletManager.activeWallet?.name ?? "", walletId: walletManager.activeWallet?.id)
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

    /// Waits while the last payment-link screen lets go of the active
    /// wallet (the short delay, then the restart), so Send does not meet a
    /// stopped wallet after a look at the Links filter. Returns at once while a
    /// screen still holds the wallet or nothing waits to restart.
    func waitForActiveWallet() async {
        guard leases == 0 else { return }
        await resumeTask?.value
        await resumeInFlight?.value
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
    /// With `estimateSweepFee`, the observation carries the claim sweep's fee.
    ///
    /// The scan must start at or below the link's restore height, and at or
    /// below `fundingHeight` when the funding block is known. Saved files
    /// are used only when they record a saved scan from there (see
    /// `openEnvelope`). An envelope whose scan started higher, or that
    /// missed a funding mined below its height, is scanned again from there:
    /// its files go and the wallet is restored from the words.
    /// - Parameters:
    ///   - fundingHeight: the funding block, when the record or the funding
    ///     wallet's history knows it.
    ///   - number: the link's number ("Link 7"), for the diagnostic log.
    func check(link: EnvelopeLink, address: String, estimateSweepFee: Bool = false, fundingHeight: UInt64? = nil, number: Int? = nil) async throws -> EnvelopeObservation {
        try await serial { [self] in
            guard let walletManager, mainSuspended else { throw RuntimeError.walletBusy }
            let name = Self.logName(number)
            let floor = EnvelopeStatusRules.scanFloor(restoreHeight: link.restoreHeight, fundingHeight: fundingHeight)
            if openEnvelopeId != link.id {
                try await openEnvelope(link, floor: floor, name: name, networkType: walletManager.networkType)
            } else {
                envelope?.startSync()
            }
            var observation: EnvelopeObservation
            var rescan = false
            var scanStart: UInt64 = 0
            do {
                guard let wallet = envelope else { throw RuntimeError.walletBusy }
                // A cached envelope reports synced at its old height before its
                // first refresh: wait for the chain tip the main wallet last saw.
                try await waitUntilSynced(wallet, atLeast: walletManager.daemonHeight)
                syncProgress = nil
                try Self.verifyAddress(of: wallet, is: address)
                observation = await observe(wallet)
                scanStart = wallet.refreshFromBlockHeight
                rescan = EnvelopeStatusRules.needsRescan(
                    scanStart: scanStart,
                    floor: floor,
                    fundingSeen: observation.fundingSeen,
                    fundingHeight: fundingHeight,
                    walletHeight: wallet.walletHeight,
                    alreadyRescanned: rescannedIds.contains(link.id)
                )
            }
            if rescan {
                DiagnosticLog.shared.log("Envelope rescan: \(name), scan started at \(scanStart), scanning from \(floor)")
                rescannedIds.insert(link.id)
                await closeEnvelopeNow()
                Self.removeFiles(id: link.id)
                try await openEnvelope(link, floor: floor, name: name, networkType: walletManager.networkType)
            }
            guard let wallet = envelope else { throw RuntimeError.walletBusy }
            if rescan {
                try await waitUntilSynced(wallet, atLeast: walletManager.daemonHeight)
                syncProgress = nil
                try Self.verifyAddress(of: wallet, is: address)
                observation = await observe(wallet)
            }
            if estimateSweepFee { observation.sweepFee = await sweepFee(wallet, balance: observation.balance) }
            DiagnosticLog.shared.log("Envelope check: \(name), height \(wallet.walletHeight)/\(wallet.daemonHeight), scan from \(wallet.refreshFromBlockHeight), funded \(observation.fundingSeen), spends \(observation.spendTxids.count), balance \(observation.balance > 0 ? "yes" : "none"), unlocked \(observation.unlockedBalance > 0 ? "yes" : "none"), confirmations \(observation.fundingConfirmations)")
            return observation
        }
    }

    /// Makes the envelope of `link` the open one. Its saved files are used
    /// only when they record a scan start at or below `floor`, written once
    /// a refresh was saved. Other files go, and the wallet is restored from
    /// the words to scan from `floor`: files saved before the first refresh
    /// (wallet2 saves a new wallet at once; the app was then killed) make
    /// wallet2 open a "new" wallet, move its start to the chain tip and
    /// skip every block below it, the funding among them, for good.
    private func openEnvelope(_ link: EnvelopeLink, floor: UInt64, name: String, networkType: MoneroKit.NetworkType) async throws {
        await closeEnvelopeNow()
        var start = floor
        if let dir = Self.directory(for: link.id), FileManager.default.fileExists(atPath: dir.path) {
            let savedStart = Self.savedScanStart(in: dir)
            if EnvelopeStatusRules.canReuseScan(savedStart: savedStart, floor: floor), let savedStart {
                start = savedStart
            } else {
                DiagnosticLog.shared.log("Envelope rebuild: \(name), \(savedStart.map { "saved scan from \($0)" } ?? "no saved scan"), scanning from \(floor)")
                Self.removeFiles(id: link.id)
            }
        }
        let wallet = MoneroWallet()
        syncProgress = 0
        Self.excludeEnvelopesFromBackup()
        try await wallet.create(
            seed: link.words,
            restoreHeight: start,
            networkType: networkType,
            cacheIdOverride: Self.cacheId(for: link.id)
        )
        envelope = wallet
        openEnvelopeId = link.id
        openScanFrom = start
        openScanRefreshedAt = nil
        openName = name
    }

    private static func verifyAddress(of wallet: MoneroWallet, is address: String) throws {
        let runtimeAddress = wallet.primaryAddress
        if !runtimeAddress.isEmpty, runtimeAddress != address {
            throw RuntimeError.addressMismatch
        }
    }

    /// "Link 7" in the diagnostic log: the number only, never the note,
    /// the address or the secret.
    nonisolated static func logName(_ number: Int?) -> String {
        number.map { "Link \($0)" } ?? "Link ?"
    }

    /// Looks for new blocks on the open envelope and returns what it sees.
    func poll(estimateSweepFee: Bool = false) async throws -> EnvelopeObservation? {
        try await serial { [self] in
            guard let wallet = envelope else { return nil }
            wallet.startSync()
            try await Task.sleep(for: .seconds(2))
            try await waitUntilSynced(wallet)
            var observation = await observe(wallet)
            if estimateSweepFee { observation.sweepFee = await sweepFee(wallet, balance: observation.balance) }
            return observation
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
            Self.removeFiles(id: id)
        }
    }

    // MARK: - Helpers

    private func closeEnvelopeNow() async {
        guard let wallet = envelope else { return }
        let id = openEnvelopeId
        let scanFrom = openScanFrom
        let refreshedAt = openScanRefreshedAt
        let name = openName ?? Self.logName(nil)
        envelope = nil
        openEnvelopeId = nil
        openScanFrom = nil
        openScanRefreshedAt = nil
        openName = nil
        syncProgress = nil
        // The kit saves the wallet as it closes. Record the scan start only
        // when that save came after a refresh: a save can fail, and a
        // wallet saved before its first refresh must never be reused.
        await wallet.stopAsync()
        if let refreshedAt, let id, let scanFrom, let dir = Self.directory(for: id),
           let saved = Self.walletSavedAt(in: dir), saved >= refreshedAt {
            Self.markScanStart(in: dir, from: scanFrom)
            DiagnosticLog.shared.log("Envelope saved: \(name), scan from \(scanFrom)")
        } else if refreshedAt != nil {
            DiagnosticLog.shared.log("Envelope save not seen: \(name), its next open scans again")
        }
    }

    private func observe(_ wallet: MoneroWallet) async -> EnvelopeObservation {
        // The kit refreshes balance and history right after it reports
        // synced; give that a moment, then read history directly.
        try? await Task.sleep(for: .milliseconds(1500))
        let txs = await wallet.fetchTransactionsBlocking()
        return Self.observation(transactions: txs, balance: wallet.balance, unlocked: wallet.unlockedBalance, daemonHeight: wallet.daemonHeight)
    }

    /// wallet2's fee estimate for the claim sweep: one input, two outputs
    /// (a sweep to one address adds a dummy change output), at the priority
    /// `sweep` uses. Nothing is built or sent.
    private func sweepFee(_ wallet: MoneroWallet, balance: UInt64) async -> UInt64? {
        guard balance > 0 else { return nil }
        let address = destination?.address ?? wallet.primaryAddress
        do {
            let fee = try await wallet.estimateFee(to: address, amount: Self.xmr(balance), priority: .default)
            return Self.piconero(fee)
        } catch {
            DiagnosticLog.shared.log("Envelope sweep fee estimate failed: \(error.localizedDescription)")
            return nil
        }
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
        // Oldest first; a funding still in the pool last.
        let fundingTxids = incoming
            .sorted { ($0.blockHeight.flatMap { $0 > 0 ? $0 : nil } ?? .max) < ($1.blockHeight.flatMap { $0 > 0 ? $0 : nil } ?? .max) }
            .map(\.id)
        return EnvelopeObservation(
            fundingSeen: !incoming.isEmpty,
            fundingConfirmations: confirmations,
            balance: piconero(balance),
            unlockedBalance: piconero(unlocked),
            spendTxids: outgoing.map(\.id),
            fundingTxids: fundingTxids,
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
            // Before the synced check: a short scan can report its first
            // height and synced in one update.
            noteRefresh(of: wallet)
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

    /// The open envelope's first refresh reached its scan start: blocks
    /// from there on are being scanned, and a save from now on resumes.
    private func noteRefresh(of wallet: MoneroWallet) {
        guard wallet === envelope, openScanRefreshedAt == nil, let scanFrom = openScanFrom,
              EnvelopeStatusRules.hasRefreshed(walletHeight: wallet.walletHeight, scanFrom: scanFrom) else { return }
        openScanRefreshedAt = Date()
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

    nonisolated static let scanStartFile = "scan-start"

    /// The height the saved scan of the envelope in `dir` started at. Nil
    /// when no refresh was saved (files from before this record, too).
    nonisolated static func savedScanStart(in dir: URL) -> UInt64? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(scanStartFile), encoding: .utf8) else { return nil }
        return UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func markScanStart(in dir: URL, from height: UInt64) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? String(height).write(to: dir.appendingPathComponent(scanStartFile), atomically: true, encoding: .utf8)
    }

    /// When the kit last saved the envelope's wallet cache (the file named
    /// "wallet" under `dir`). Nil when there is none.
    nonisolated static func walletSavedAt(in dir: URL) -> Date? {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: Date?
        for case let url as URL in files where url.lastPathComponent == "wallet" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            newest = max(newest ?? date, date)
        }
        return newest
    }

    /// Deletes the envelope's wallet files (never the record or its secret).
    private static func removeFiles(id: String) {
        guard EnvelopeLink.isEnvelopeId(id), let dir = directory(for: id) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

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

    /// The active wallet's main address, the one the wallet switcher shows.
    /// Every wallet takes a claim at its main address.
    static func mainAddress(of walletManager: WalletManager) -> String? {
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
