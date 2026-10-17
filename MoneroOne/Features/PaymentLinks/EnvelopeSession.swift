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
    /// The wallets the money can go to, in wallet switcher order. The sheet
    /// offers a choice when there are two or more.
    @Published private(set) var destinations: [PaymentLinkClaimDestination] = []
    /// The wallet the money goes to.
    @Published var destinationId: UUID?

    /// The chosen wallet, nil when no list could be read.
    var destination: PaymentLinkClaimDestination? {
        destinations.first { $0.walletId == destinationId }
    }

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
        var record = record
        record.status = EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid)
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
        sweepTarget?.walletName ?? walletManager.activeWallet?.name ?? ""
    }

    /// The chosen wallet; with no list (none could be read), the active
    /// wallet's receive address as before.
    private var sweepTarget: (address: String, walletName: String)? {
        if let chosen = destination {
            return (chosen.address, chosen.name)
        }
        return runtime.destination.map { ($0.address, $0.walletName) }
    }

    // MARK: - Lifecycle

    /// Opens the envelope and checks it. Keeps looking for new blocks while
    /// the money is on its way. A claimed or reclaimed link shows its result
    /// with no scan: a scan would stop the active wallet on every open, and
    /// one made before our claim is mined still sees the money. The link's
    /// detail looks once for money left behind (PaymentLinksStatusChecker).
    func start() async {
        stopped = false
        pollTask?.cancel()
        guard let link = record.link, !record.status.isSettled else {
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
            loadDestinations()
            watchProgress()
            let observation = try await runtime.check(
                link: link,
                address: record.address,
                estimateSweepFee: record.role == .received,
                fundingHeight: fundingHeight,
                number: record.number
            )
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
    /// unlocked to the chosen wallet. A closed wallet stays closed; the
    /// money shows when it next syncs.
    func sweep() async {
        guard case .ready = phase, let destination = sweepTarget else { return }
        pollTask?.cancel()
        phase = .sweeping
        do {
            let result = try await runtime.sweep(envelopeId: record.id, envelopeAddress: record.address, to: destination.address)
            record.settleTxid = result.txid
            record.settledAmount = result.amount
            record.walletName = destination.walletName
            record.settledAt = Date()
            record.status = record.role == .sent ? .reclaimed : .claimed
            PaymentLinksStatusChecker.settledLooks.remove(record.id)
            // Keep the secret until explicit Remove All: a mined sweep can
            // reorg, or leave newer locked funding in this envelope.
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

    /// Reads the wallets the money can go to. Keeps the user's pick when
    /// it is still in the list, else takes the default.
    private func loadDestinations() {
        let list = PaymentLinkClaimDestinations.eligible(
            wallets: walletManager.wallets,
            active: runtime.destination,
            activeBalance: walletManager.displayBalance,
            isValidAddress: { walletManager.isValidAddress($0) }
        )
        destinations = list
        if !list.contains(where: { $0.walletId == destinationId }) {
            destinationId = PaymentLinkClaimDestinations.defaultChoice(
                among: list,
                role: record.role,
                fundingWalletId: record.walletId,
                activeWalletId: runtime.destination?.walletId
            )?.walletId
        }
    }

    // MARK: - Status

    /// A sent link's funding block, where the envelope's scan must start.
    private var fundingHeight: UInt64? {
        PaymentLinksStatusChecker.fundingHeight(of: record, in: walletManager.transactions)
    }

    private func update(with observation: EnvelopeObservation) {
        // The store's copy may have learned the funding since this screen
        // opened (the Send flow marks it funded after the broadcast).
        if let stored = store.record(id: record.id, role: record.role), record.fundingTxid == nil {
            record.fundingTxid = stored.fundingTxid
        }
        record = PaymentLinksStatusChecker.applying(observation, to: record, transactions: walletManager.transactions, now: Date()).record
        let status = record.status
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
                guard let observation = try? await self.runtime.poll(envelopeId: self.record.id, estimateSweepFee: self.record.role == .received), !Task.isCancelled else { continue }
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

/// A wallet a claim or reclaim can send the money to, with what its
/// switcher row shows.
struct PaymentLinkClaimDestination: Identifiable, Equatable {
    let wallet: WalletInfo
    /// The wallet's main address: the claim pays it, the row shows it.
    let address: String
    /// The open wallet's balance, or a closed wallet's last known one. Nil
    /// when unknown.
    let balance: Decimal?
    /// The wallet the app has open (the one the envelope stopped).
    let isOpen: Bool

    var id: UUID { wallet.id }
    var walletId: UUID { wallet.id }
    var name: String { wallet.name }
}

/// Which wallets a payment link can be claimed into, and the one it goes to
/// unless the user picks another. Choosing a wallet does not open it: the
/// sweep goes to its main address and the money shows when it next syncs.
enum PaymentLinkClaimDestinations {
    /// In wallet switcher order, each at its main address: the open wallet
    /// at the address the runtime read before it stopped, every other
    /// wallet at its saved one when that is valid on this network. A wallet
    /// without one is left out. View-only and hardware wallets can receive,
    /// so they stay in.
    static func eligible(
        wallets: [WalletInfo],
        active: EnvelopeRuntime.Destination?,
        activeBalance: Decimal?,
        isValidAddress: (String) -> Bool
    ) -> [PaymentLinkClaimDestination] {
        wallets.compactMap { wallet in
            if let active, active.walletId == wallet.id {
                return PaymentLinkClaimDestination(wallet: wallet, address: active.address, balance: activeBalance, isOpen: true)
            }
            guard let address = wallet.cachedPrimaryAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !address.isEmpty,
                  !NullKeyAddress.isNullKey(address),
                  isValidAddress(address) else { return nil }
            return PaymentLinkClaimDestination(wallet: wallet, address: address, balance: wallet.cachedBalance, isOpen: false)
        }
    }

    /// Claim: the open wallet. Reclaim: the wallet that funded the link, when
    /// it can still receive, else the open wallet.
    static func defaultChoice(
        among destinations: [PaymentLinkClaimDestination],
        role: EnvelopeRecord.Role,
        fundingWalletId: String?,
        activeWalletId: UUID?
    ) -> PaymentLinkClaimDestination? {
        if role == .sent, let fundingId = fundingWalletId.flatMap(UUID.init(uuidString:)),
           let funding = destinations.first(where: { $0.walletId == fundingId }) {
            return funding
        }
        return destinations.first { $0.walletId == activeWalletId }
    }
}
