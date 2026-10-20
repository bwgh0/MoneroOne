import SwiftUI

/// One Money arrives moment on the balance card: the payments that came in
/// since the card last showed one.
struct MoneyArrival: Equatable, Identifiable {
    let id = UUID()
    /// XMR: the sum of the payments.
    let amount: Decimal
    /// The balance the card showed before the payments. The hero keeps it
    /// until the +amount rises into it.
    let fromBalance: Decimal
    /// The wallet's first payment: the bigger moment.
    let isFirstPayment: Bool
}

/// When the balance card plays Money arrives. Pure rules, for the tests.
///
/// Each wallet keeps a baseline: the newest block whose incoming payments
/// the card has shown. A payment above it, in a block, is an arrival. A
/// sync that sets the baseline (the first sync of a wallet, or one after a
/// rescan) plays nothing: the baseline becomes the top of the chain.
enum MoneyArrivalRules {
    /// The payments the card has not shown: incoming, not failed, with 1
    /// or more confirmations, in a block above `baseline`. `excludedIds`:
    /// our reclaims of links we sent (our own money coming back).
    static func arrivals(
        in transactions: [MoneroTransaction],
        baseline: UInt64,
        excluding excludedIds: Set<String> = []
    ) -> [MoneroTransaction] {
        transactions.filter { tx in
            guard isLivePayment(tx, excluding: excludedIds) else { return false }
            let confirmations: Int = tx.confirmations ?? 0
            let height: UInt64 = tx.blockHeight ?? 0
            return confirmations >= 1 && height > baseline
        }
    }

    /// An incoming payment that did not fail and is not excluded.
    private static func isLivePayment(_ tx: MoneroTransaction, excluding excludedIds: Set<String>) -> Bool {
        guard tx.type == .incoming, tx.status != .failed else { return false }
        return !excludedIds.contains(tx.id)
    }

    /// XMR: what the arrivals add up to.
    static func total(of arrivals: [MoneroTransaction]) -> Decimal {
        arrivals.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// True when the wallet scanned up to the chain's top.
    static func isSyncDone(isSynced: Bool, walletHeight: UInt64, daemonHeight: UInt64) -> Bool {
        guard isSynced, walletHeight > 0, daemonHeight > 0 else { return false }
        return walletHeight + 1 >= daemonHeight
    }

    /// The baseline that a finished sync sets with no moment: every block
    /// the wallet scanned (`walletHeight` counts blocks, so its top block
    /// is one less), and every transaction it lists.
    static func baseline(transactions: [MoneroTransaction], walletHeight: UInt64) -> UInt64 {
        let top = walletHeight > 0 ? walletHeight - 1 : 0
        let newest = transactions.compactMap(\.blockHeight).max() ?? 0
        return max(top, newest)
    }

    /// The baseline after a moment showed `arrivals`.
    static func baseline(after arrivals: [MoneroTransaction], current: UInt64) -> UInt64 {
        max(current, arrivals.compactMap(\.blockHeight).max() ?? current)
    }

    /// A baseline above the wallet's top block belongs to another chain
    /// (a test chain, say). The next finished sync sets it again.
    static func isBaselineValid(_ baseline: UInt64, walletHeight: UInt64) -> Bool {
        walletHeight == 0 || baseline < walletHeight
    }

    /// The bigger moment: a wallet made in this app (`isEligible`) whose
    /// history holds only these arrivals, none of them a payment link
    /// claim (`claimIds`).
    static func isFirstPayment(
        isEligible: Bool,
        transactions: [MoneroTransaction],
        arrivals: [MoneroTransaction],
        claimIds: Set<String> = []
    ) -> Bool {
        guard isEligible, !arrivals.isEmpty else { return false }
        let arrivalIds = Set(arrivals.map(\.id))
        guard transactions.allSatisfy({ arrivalIds.contains($0.id) }) else { return false }
        return arrivalIds.isDisjoint(with: claimIds)
    }

    /// The balance the hero shows. Payments not shown yet stay out of it
    /// until their moment. A rise that the history has not explained yet
    /// (the balance can come a moment before the history that shows its
    /// payment) holds at `balanceAtHistory` while a payment waits in the
    /// pool.
    static func heroBalance(
        balance: Decimal,
        pendingTotal: Decimal,
        balanceAtHistory: Decimal?,
        hasPoolPayment: Bool
    ) -> Decimal {
        if pendingTotal > 0 {
            return max(0, balance - pendingTotal)
        }
        if let balanceAtHistory, hasPoolPayment, balance > balanceAtHistory {
            return balanceAtHistory
        }
        return balance
    }

    /// An incoming payment in the pool (no block yet). Its first block is
    /// an arrival.
    static func hasPoolPayment(in transactions: [MoneroTransaction], excluding excludedIds: Set<String> = []) -> Bool {
        transactions.contains { tx in
            guard isLivePayment(tx, excluding: excludedIds) else { return false }
            let confirmations: Int = tx.confirmations ?? 0
            return confirmations == 0
        }
    }
}

/// Money arrives: the hero's hold while the wallet catches up (a launch, a
/// return to the app, a wallet switch) and at each new block while Synced.
/// A payment that a scan finds stays out of the hero until its moment: the
/// hero does not tick up and back. The kit reports Synced, and each new
/// height, before the balance and history of that scan, so the hold ends
/// at the first history after it. Pure, for the tests.
struct MoneyArrivalHold: Equatable {
    /// The wallet's sync, as the hold sees it.
    enum Phase {
        /// Idle, connecting or failed. Nothing scans, so the balance is
        /// the one the wallet stored.
        case waiting
        case syncing
        case synced
    }

    /// The hero's value while the hold lasts. Nil: no hold.
    private(set) var held: Decimal?
    /// Synced: the next history ends the hold.
    private(set) var awaitsHistory = false
    /// Counts the scans that the hold waits for, so each one gets its own
    /// 3 s fallback.
    private(set) var scans = 0

    /// Changes at each scan that the hold waits for. Nil: no wait.
    var historyWait: Int? { awaitsHistory ? scans : nil }

    /// The sync moved from `old` to `new`. A scan (syncing, or Synced from
    /// another phase) holds the hero at `shown`, the value it shows now.
    /// `canHold`: the wallet has a baseline and no moment plays.
    mutating func syncMoved(from old: Phase, to new: Phase, shown: Decimal, canHold: Bool) {
        switch new {
        case .waiting:
            break
        case .syncing:
            if held == nil, canHold { held = shown }
            awaitsHistory = false
        case .synced:
            guard old != .synced else { return }
            if held == nil, canHold { held = shown }
            awaitsHistory = held != nil
            scans += 1
        }
    }

    /// The wallet's height went up while Synced: a new block. Its balance
    /// can come before its history (a payment that the pool never showed),
    /// so the hero holds at `shown` until that history. A hold that runs
    /// keeps its value.
    mutating func blockAdded(shown: Decimal, canHold: Bool) {
        if held == nil {
            guard canHold else { return }
            held = shown
        }
        awaitsHistory = true
        scans += 1
    }

    /// A new history. At Synced it ends the hold: the history now shows
    /// the payments that the balance holds.
    mutating func historyChanged() {
        guard awaitsHistory else { return }
        end()
    }

    /// A moment plays, a wallet session starts, or Synced brought no new
    /// history in time.
    mutating func end() {
        held = nil
        awaitsHistory = false
    }
}

/// Per wallet: the baseline (per network) and the first-payment flag, in
/// UserDefaults. Neither is secret: a block height and a flag.
struct MoneyArrivalStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func network(isTestnet: Bool) -> String { isTestnet ? "testnet" : "mainnet" }

    private func baselineKey(walletId: UUID, network: String) -> String {
        "moneyArrival.\(network).baseline.\(walletId.uuidString)"
    }

    private func firstPaymentKey(walletId: UUID) -> String {
        "moneyArrival.firstPayment.\(walletId.uuidString)"
    }

    func baseline(walletId: UUID, network: String) -> UInt64? {
        (defaults.object(forKey: baselineKey(walletId: walletId, network: network)) as? NSNumber)?.uint64Value
    }

    func setBaseline(_ height: UInt64, walletId: UUID, network: String) {
        defaults.set(NSNumber(value: height), forKey: baselineKey(walletId: walletId, network: network))
    }

    /// A rescan: the next finished sync sets the baseline again, with no
    /// moment.
    func forgetBaseline(walletId: UUID, network: String) {
        defaults.removeObject(forKey: baselineKey(walletId: walletId, network: network))
    }

    /// Create Wallet made this wallet: its first payment gets the bigger
    /// moment. Restored and imported wallets never do.
    func markFirstPaymentEligible(walletId: UUID) {
        defaults.set(true, forKey: firstPaymentKey(walletId: walletId))
    }

    func isFirstPaymentEligible(walletId: UUID) -> Bool {
        defaults.bool(forKey: firstPaymentKey(walletId: walletId))
    }

    /// A moment played: the bigger one is used up.
    func firstPaymentUsed(walletId: UUID) {
        defaults.removeObject(forKey: firstPaymentKey(walletId: walletId))
    }
}

// MARK: - Wallet home

/// The active wallet's Money arrives state, read fresh on each render.
@MainActor
struct MoneyArrivalWatch {
    let walletManager: WalletManager
    let links: EnvelopeStore
    var store = MoneyArrivalStore()

    var walletId: UUID? { walletManager.activeWallet?.id }

    var network: String { MoneyArrivalStore.network(isTestnet: walletManager.isTestnet) }

    /// The stored baseline, if it fits this chain.
    var baseline: UInt64? {
        guard let walletId, let baseline = store.baseline(walletId: walletId, network: network),
              MoneyArrivalRules.isBaselineValid(baseline, walletHeight: walletManager.walletHeight) else { return nil }
        return baseline
    }

    /// The txids of the history's payment-link transactions of one kind.
    func linkTransactionIds(_ kind: PaymentLinkActivity.Kind) -> Set<String> {
        Set(walletManager.transactions
            .filter { PaymentLinkActivity.match($0, store: links)?.kind == kind }
            .map(\.id))
    }

    /// Payments that wait for their moment.
    var pending: [MoneroTransaction] {
        guard let baseline else { return [] }
        return MoneyArrivalRules.arrivals(
            in: walletManager.transactions,
            baseline: baseline,
            excluding: linkTransactionIds(.reclaim)
        )
    }

    /// The hero's balance while payments wait. Nil: the wallet's balance.
    func heroBalance(balanceAtHistory: Decimal?) -> Decimal? {
        guard baseline != nil else { return nil }
        let balance = walletManager.displayBalance
        let shown = MoneyArrivalRules.heroBalance(
            balance: balance,
            pendingTotal: MoneyArrivalRules.total(of: pending),
            balanceAtHistory: balanceAtHistory,
            hasPoolPayment: MoneyArrivalRules.hasPoolPayment(
                in: walletManager.transactions,
                excluding: linkTransactionIds(.reclaim)
            )
        )
        return shown == balance ? nil : shown
    }

    var isSynced: Bool {
        if case .synced = walletManager.syncState { return true }
        return false
    }

    var isSyncDone: Bool {
        MoneyArrivalRules.isSyncDone(
            isSynced: isSynced,
            walletHeight: walletManager.walletHeight,
            daemonHeight: walletManager.daemonHeight
        )
    }
}

/// Plays Money arrives on the wallet home: while the Wallet tab shows the
/// balance at Now (`isIdle`: unlocked, no sheet, History, chart point or
/// wallet list) and the wallet is Synced. A catch-up plays once its last
/// history is in, so its payments make one +amount. Payments that came
/// meanwhile wait for the next visit. A wallet with no baseline gets one,
/// with no moment, when its sync reaches the top.
private struct MoneyArrivalTrigger: ViewModifier {
    let isIdle: Bool
    @Binding var playing: MoneyArrival?
    @Binding var balanceAtHistory: Decimal?
    @Binding var hold: MoneyArrivalHold
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var links = EnvelopeStore.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Bumped after a baseline write, which UserDefaults does not publish.
    @State private var revision = 0

    private struct Check: Equatable {
        let walletId: UUID?
        let canPlay: Bool
        let needsBaseline: Bool
        let pendingIds: [String]
        let revision: Int
    }

    private var watch: MoneyArrivalWatch { MoneyArrivalWatch(walletManager: walletManager, links: links) }

    private var syncPhase: MoneyArrivalHold.Phase {
        switch walletManager.syncState {
        case .syncing: return .syncing
        case .synced: return .synced
        case .idle, .connecting, .error: return .waiting
        }
    }

    /// What the hero shows with no hold.
    private var shownHero: Decimal {
        watch.heroBalance(balanceAtHistory: balanceAtHistory) ?? walletManager.displayBalance
    }

    private func syncMoved(from old: MoneyArrivalHold.Phase, to new: MoneyArrivalHold.Phase) {
        let canHold: Bool = watch.baseline != nil && playing == nil
        hold.syncMoved(from: old, to: new, shown: shownHero, canHold: canHold)
    }

    private var check: Check {
        let watch = watch
        let isActive: Bool = scenePhase == .active
        let isSteady: Bool = watch.isSynced && !walletManager.isSwitchingWallet && !hold.awaitsHistory
        let hasNoBaseline: Bool = watch.baseline == nil
        return Check(
            walletId: watch.walletId,
            canPlay: isIdle && isActive && isSteady,
            needsBaseline: hasNoBaseline && watch.isSyncDone,
            pendingIds: watch.pending.map(\.id),
            revision: revision
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: check) { await run() }
            .task(id: hold.historyWait) { await endHoldWithNoHistory() }
            .onAppear {
                balanceAtHistory = walletManager.displayBalance
                // Shown during a scan (a wallet switch): hold from here.
                if syncPhase == .syncing { syncMoved(from: .waiting, to: .syncing) }
            }
            .onChange(of: syncPhase) { old, new in syncMoved(from: old, to: new) }
            .onChange(of: walletManager.walletHeight) { old, new in
                guard new > old, syncPhase == .synced else { return }
                let canHold: Bool = watch.baseline != nil && playing == nil
                hold.blockAdded(shown: shownHero, canHold: canHold)
            }
            // Each new history, also one that only confirms a payment that
            // was in the pool: the transactions' == compares ids only.
            .onChange(of: walletManager.transactions.map(\.rowState)) { _, _ in
                balanceAtHistory = walletManager.displayBalance
                hold.historyChanged()
            }
            .onChange(of: walletManager.walletSessionId) { _, _ in
                playing = nil
                balanceAtHistory = nil
                hold.end()
            }
    }

    /// Synced, and no new history 3 s after the scan: the hold ends.
    private func endHoldWithNoHistory() async {
        guard hold.awaitsHistory else { return }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        hold.end()
    }

    private func run() async {
        let watch = watch
        guard let walletId = watch.walletId, !walletManager.isSwitchingWallet else { return }

        guard let baseline = watch.baseline else {
            // First sync, restore, import or rescan: everything so far is
            // seen. No moment.
            guard watch.isSyncDone else { return }
            let height = MoneyArrivalRules.baseline(
                transactions: walletManager.transactions,
                walletHeight: walletManager.walletHeight
            )
            watch.store.setBaseline(height, walletId: walletId, network: watch.network)
            revision += 1
            return
        }

        let check = check
        guard check.canPlay, !check.pendingIds.isEmpty, playing == nil else { return }
        // Nothing presented over the root, a sheet that is closing too,
        // for half a second.
        var quietChecks = 0
        while quietChecks < 2 {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            quietChecks = SendRequestPresenter.isSheetShowing ? 0 : quietChecks + 1
        }

        let arrivals = watch.pending
        guard !arrivals.isEmpty, watch.walletId == walletId else { return }
        let from = hold.held ?? shownHero
        let isFirst = MoneyArrivalRules.isFirstPayment(
            isEligible: watch.store.isFirstPaymentEligible(walletId: walletId),
            transactions: walletManager.transactions,
            arrivals: arrivals,
            claimIds: watch.linkTransactionIds(.claim)
        )
        watch.store.setBaseline(
            MoneyArrivalRules.baseline(after: arrivals, current: baseline),
            walletId: walletId,
            network: watch.network
        )
        watch.store.firstPaymentUsed(walletId: walletId)
        revision += 1
        hold.end()
        playing = MoneyArrival(
            amount: MoneyArrivalRules.total(of: arrivals),
            fromBalance: from,
            isFirstPayment: isFirst
        )
    }
}

extension View {
    /// For the wallet home: plays Money arrives on the balance card.
    func playsMoneyArrivals(
        isIdle: Bool,
        playing: Binding<MoneyArrival?>,
        balanceAtHistory: Binding<Decimal?>,
        hold: Binding<MoneyArrivalHold>
    ) -> some View {
        modifier(MoneyArrivalTrigger(isIdle: isIdle, playing: playing, balanceAtHistory: balanceAtHistory, hold: hold))
    }
}
