import Foundation
import MoneroKit

/// Drives one payment link on screen: opens its envelope wallet, keeps its
/// status current, and claims or reclaims it. The claim sheet and the sent
/// link's detail both use it.
@MainActor
final class EnvelopeSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Syncing the envelope; progress 0...1 when known.
        case checking(progress: Double?)
        /// Funding seen, not unlocked yet.
        case waiting(confirmations: Int)
        /// Claimable: unlocked piconero.
        case ready(unlocked: UInt64)
        case sweeping
        case done(txid: String, amount: UInt64)
        /// Nothing to claim: no funding yet, or it was spent.
        case noFunding
        case alreadyClaimed
        case reclaimed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var record: EnvelopeRecord
    /// A received link: claim on the first check that finds it ready (the
    /// user tapped Claim on its row in Activity). Once only.
    var claimWhenReady = false

    private let walletManager: WalletManager
    private let store: EnvelopeStore
    private let runtime: EnvelopeRuntime
    private var leased = false
    private var stopped = false
    private var pollTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    /// Blocks are 2 minutes; look for new ones well inside that.
    private static let pollInterval: Duration = .seconds(15)

    init(record: EnvelopeRecord, walletManager: WalletManager, store: EnvelopeStore = .shared, runtime: EnvelopeRuntime = .shared) {
        self.record = record
        self.walletManager = walletManager
        self.store = store
        self.runtime = runtime
    }

    var isSweeping: Bool {
        if case .sweeping = phase { return true }
        return false
    }

    var destinationWalletName: String {
        runtime.destination?.walletName ?? walletManager.activeWallet?.name ?? ""
    }

    // MARK: - Lifecycle

    /// Opens the envelope and checks it. Keeps looking for new blocks while
    /// the money is on its way.
    func start() async {
        stopped = false
        pollTask?.cancel()
        guard let link = record.link else {
            apply(status: record.status, observation: nil)
            return
        }
        phase = .checking(progress: nil)
        do {
            if !leased {
                try await runtime.acquire(walletManager)
                leased = true
                // The screen closed while the active wallet was stopping:
                // give the lease straight back.
                if stopped {
                    leased = false
                    runtime.release()
                    return
                }
            }
            watchProgress()
            let observation = try await runtime.check(link: link, address: record.address, estimateSweepFee: record.role == .received)
            progressTask?.cancel()
            update(with: observation)
            guard !stopped else { return }
            schedulePolling()
        } catch {
            progressTask?.cancel()
            phase = .failed(Self.message(for: error))
        }
    }

    /// The screen went away: stop polling and let the active wallet start
    /// again.
    func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        progressTask?.cancel()
        progressTask = nil
        if leased {
            leased = false
            runtime.release()
        }
    }

    /// Claim (received link) or reclaim (sent link): sweep everything
    /// unlocked to the active wallet's receive address.
    func sweep() async {
        guard case .ready = phase, let destination = runtime.destination else { return }
        pollTask?.cancel()
        phase = .sweeping
        do {
            let result = try await runtime.sweep(to: destination.address)
            record.settleTxid = result.txid
            record.settledAmount = result.amount
            record.walletName = destination.walletName
            record.settledAt = Date()
            record.status = record.role == .sent ? .reclaimed : .claimed
            // A received link keeps its words until the claim is mined
            // (PaymentLinksStatusChecker.forgetMinedClaimWords): a claim
            // that never confirms can be made again.
            try? store.save(record)
            phase = .done(txid: result.txid, amount: result.amount)
            await runtime.deleteFiles(id: record.id)
        } catch EnvelopeRuntime.RuntimeError.alreadyClaimed {
            record.status = .claimed
            try? store.save(record)
            phase = .alreadyClaimed
            await runtime.deleteFiles(id: record.id)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: - Status

    private func update(with observation: EnvelopeObservation) {
        let reclaimTxid = record.role == .sent ? record.settleTxid : nil
        let status = EnvelopeStatusRules.status(
            for: observation,
            reclaimTxid: reclaimTxid,
            reclaimAge: record.settledAt.map { Date().timeIntervalSince($0) }
        )
        record.noteBalance(observation.balance, sweepFee: observation.sweepFee)
        record.confirmations = observation.fundingConfirmations
        record.fundingHeight = observation.fundingHeight
        record.lastCheckedAt = Date()
        record.status = status
        try? store.save(record)
        apply(status: status, observation: observation)
        if status.isSettled {
            Task { await runtime.deleteFiles(id: record.id) }
        }
    }

    private func apply(status: EnvelopeStatus, observation: EnvelopeObservation?) {
        switch status {
        case .created, .notFunded:
            phase = .noFunding
        case .pending:
            phase = .waiting(confirmations: observation?.fundingConfirmations ?? record.confirmations ?? 0)
        case .ready:
            phase = .ready(unlocked: observation?.unlockedBalance ?? record.lastBalance ?? 0)
            if claimWhenReady, record.role == .received, observation != nil {
                claimWhenReady = false
                Task { await sweep() }
            }
        case .claimed:
            if record.role == .received, let txid = record.settleTxid {
                phase = .done(txid: txid, amount: record.settledAmount ?? 0)
            } else {
                phase = .alreadyClaimed
            }
        case .reclaimed:
            if record.role == .sent, let txid = record.settleTxid {
                phase = .done(txid: txid, amount: record.settledAmount ?? 0)
            } else {
                phase = .reclaimed
            }
        }
    }

    private func schedulePolling() {
        pollTask?.cancel()
        let waiting: Bool
        switch phase {
        case .waiting, .noFunding: waiting = true
        // A sent link that is ready can still be claimed by the recipient.
        case .ready: waiting = record.role == .sent
        default: waiting = false
        }
        guard waiting else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                if case .sweeping = self.phase { return }
                guard let observation = try? await self.runtime.poll(estimateSweepFee: self.record.role == .received), !Task.isCancelled else { continue }
                self.update(with: observation)
                if self.record.status.isSettled { return }
            }
        }
    }

    private func watchProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .checking = self.phase {
                    self.phase = .checking(progress: self.runtime.syncProgress)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
