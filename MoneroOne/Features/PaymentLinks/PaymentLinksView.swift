import SwiftUI
import MoneroKit

// MARK: - Status

struct PaymentLinkStatusChip: View {
    let display: PaymentLinkDisplay

    var body: some View {
        Text(display.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(display.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(display.tint.opacity(0.15))
            .clipShape(Capsule())
    }
}

/// Label and colors for a record's status. Sent links that are not on chain
/// long enough read their confirmations from the active wallet's own
/// funding transaction, so Activity stays current without opening the
/// envelope.
struct PaymentLinkDisplay {
    let status: EnvelopeStatus
    let isExpired: Bool
    let confirmations: Int?
    let role: EnvelopeRecord.Role
    let claimedHere: Bool

    @MainActor
    init(record: EnvelopeRecord, walletManager: WalletManager?, now: Date = Date()) {
        var fundingConfirmations: Int?
        let status = EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid)
        if record.role == .sent, status == .pending || status == .created,
           let txid = record.fundingTxid,
           let tx = walletManager?.transactions.first(where: { $0.id == txid }) {
            fundingConfirmations = tx.confirmations
        }
        self.init(record: record, fundingConfirmations: fundingConfirmations, daemonHeight: walletManager?.daemonHeight, now: now)
    }

    /// - Parameters:
    ///   - fundingConfirmations: a sent link's funding in the active
    ///     wallet's history, its live count; nil when that wallet did not
    ///     fund it.
    ///   - daemonHeight: the active wallet's.
    init(record: EnvelopeRecord, fundingConfirmations: Int?, daemonHeight: UInt64?, now: Date = Date()) {
        // A sent link with a funding transaction waits for it, whatever a
        // check that missed it wrote.
        var status = EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid)
        var confirmations = record.confirmations
        if record.role == .sent, status == .pending || status == .created, let fundingConfirmations {
            confirmations = fundingConfirmations
            if status == .created { status = .pending }
        }
        // A received link, or a sent link another wallet funded: the funding
        // height of the last check and the active wallet's daemon height give
        // a live count.
        if status == .pending, record.role == .received || fundingConfirmations == nil,
           let height = record.fundingHeight,
           let daemonHeight, daemonHeight > height {
            confirmations = max(confirmations ?? 0, Int(daemonHeight - height))
        }
        // Same rule as the link's row in Activity, so both say the same.
        if record.role == .received, status == .pending,
           PendingPaymentLinks.state(of: record, daemonHeight: daemonHeight ?? 0, now: now) == .ready {
            status = .ready
        }
        // A sent link unlocks with its funding: at 10 confirmations it is
        // ready, whatever the last check said (a check that failed, or ran
        // before the unlock). Its Activity row, this label and Reclaim then
        // agree. The reclaim sheet opens the envelope and tells ready from
        // claimed before anything moves; the next check corrects the record.
        if record.role == .sent, status == .pending,
           (confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock {
            status = .ready
        }
        self.status = status
        self.confirmations = confirmations
        self.role = record.role
        self.claimedHere = record.role == .received && record.settleTxid != nil
        self.isExpired = EnvelopeStatusRules.isExpired(status, expiry: record.expiry, now: now)
            || EnvelopeStatusRules.isReceivedExpired(status, role: record.role, expiry: record.expiry, receivedAt: record.createdAt, now: now)
    }

    /// A sent link's Reclaim button is on.
    var canReclaim: Bool { role == .sent && status == .ready }

    var label: String {
        if isExpired { return String(localized: "Expired") }
        switch status {
        case .created:
            return role == .sent ? String(localized: "Not funded") : String(localized: "Not checked")
        case .notFunded:
            return role == .sent ? String(localized: "Not funded") : PendingPaymentLinks.label(for: .noMoney)
        case .pending:
            if let confirmations {
                return String(localized: "Pending \(min(confirmations, EnvelopeLink.confirmationsToUnlock))/\(EnvelopeLink.confirmationsToUnlock)")
            }
            return String(localized: "Pending")
        case .ready:
            return role == .sent ? String(localized: "Ready") : String(localized: "Ready to claim")
        case .claimed:
            if role == .received { return claimedHere ? String(localized: "Claimed") : String(localized: "Already claimed") }
            return String(localized: "Claimed")
        case .reclaimed:
            return String(localized: "Reclaimed")
        }
    }

    var tint: Color {
        if isExpired { return .yellow }
        switch status {
        case .created: return role == .sent ? .red : .gray
        case .notFunded: return role == .sent ? .red : .gray
        case .pending: return .brand
        case .ready: return .green
        case .claimed: return claimedHere || role == .sent ? .green : .gray
        case .reclaimed: return .gray
        }
    }

    var textColor: Color {
        // Yellow text is hard to read; a caution chip keeps the label color.
        isExpired ? .primary : tint
    }
}

// MARK: - Background status check

/// Opens each sent link that someone could have claimed since the last look,
/// one at a time, while the dashboard (the balance card's open-link lines),
/// Activity's Links filter or a link's detail is on screen.
@MainActor
final class PaymentLinksStatusChecker: ObservableObject {
    @Published private(set) var isChecking = false
    private var task: Task<Void, Never>?
    /// When a look at each link last failed. A failure sets no
    /// lastCheckedAt; without this, every new block would try again.
    private var lastFailedLook: [String: Date] = [:]

    /// `only`: look at that one link (its detail is on screen).
    /// `matching`: look only at the links it accepts (the dashboard: the
    /// active wallet's open links).
    func start(
        walletManager: WalletManager,
        store: EnvelopeStore,
        only recordId: String? = nil,
        matching include: ((EnvelopeRecord) -> Bool)? = nil
    ) {
        guard task == nil else { return }
        // Pending links this wallet funded need no envelope: their
        // confirmations come from the active wallet. Only links that can
        // have moved are opened.
        let now = Date()
        let candidates = store.sent.filter { record in
            guard record.link != nil, recordId == nil || record.id == recordId,
                  include?(record) ?? true else { return false }
            // One look per block is enough; a scan stops the active wallet.
            let last = [record.lastCheckedAt, lastFailedLook[record.id]].compactMap { $0 }.max()
            if let last, now.timeIntervalSince(last) < Self.recheckInterval { return false }
            switch EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid) {
            case .ready: return true
            case .reclaimed:
                // The reclaim reached this wallet: nothing left to watch.
                // Not seen here: look whether it dropped.
                guard let txid = record.settleTxid else { return false }
                return !walletManager.transactions.contains { $0.id == txid && $0.status != .failed }
            case .pending:
                // Another wallet sent the funding: this wallet's history has
                // no count for it, and the record keeps the one from the last
                // look. The envelope gives a fresh one.
                if let txid = record.fundingTxid, !walletManager.transactions.contains(where: { $0.id == txid }) {
                    return true
                }
                // Unlocked by its count: the envelope tells ready from claimed.
                let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
                return (display.confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock
            default: return false
            }
        }
        guard !candidates.isEmpty else { return }
        isChecking = true
        task = Task { [weak self] in
            var leased = false
            defer {
                if leased { EnvelopeRuntime.shared.release() }
                self?.isChecking = false
                self?.task = nil
            }
            do {
                try await EnvelopeRuntime.shared.acquire(walletManager)
                leased = true
            } catch {
                DiagnosticLog.shared.log("Payment link check skipped: \(error.localizedDescription)")
                return
            }
            for candidate in candidates {
                guard !Task.isCancelled, let link = candidate.link,
                      var record = store.record(id: candidate.id, role: .sent) else { continue }
                let observation: EnvelopeObservation
                do {
                    observation = try await EnvelopeRuntime.shared.check(
                        link: link,
                        address: record.address,
                        fundingHeight: Self.fundingHeight(of: record, in: walletManager.transactions),
                        number: record.number
                    )
                } catch {
                    DiagnosticLog.shared.log("Payment link check failed: \(EnvelopeRuntime.logName(record.number)): \(error.localizedDescription)")
                    if !Task.isCancelled { self?.lastFailedLook[candidate.id] = Date() }
                    continue
                }
                if record.fundingTxid == nil { record.fundingTxid = observation.fundingTxids.first }
                let status = EnvelopeStatusRules.status(
                    for: observation,
                    reclaimTxid: record.settleTxid,
                    reclaimAge: record.settledAt.map { Date().timeIntervalSince($0) },
                    fundingKnown: record.fundingTxid != nil
                )
                record.status = status
                record.lastBalance = observation.balance
                record.confirmations = observation.fundingConfirmations
                record.fundingHeight = observation.fundingHeight ?? record.fundingHeight
                record.lastCheckedAt = Date()
                try? store.save(record)
                if status.isSettled {
                    await EnvelopeRuntime.shared.deleteFiles(id: record.id)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    static let recheckInterval: TimeInterval = 120

    private static var lastNetAmountFill: Date?

    /// Received links checked before records had a net amount: their last
    /// balance less the active wallet's fee estimate (one input, two
    /// outputs, as the claim sweep). The claim sheet's next check replaces
    /// it with the envelope's own estimate. At most every 10 minutes.
    static func fillNetAmounts(store: EnvelopeStore, walletManager: WalletManager, now: Date = Date()) {
        guard let balance = store.received.first(where: \.needsNetAmount)?.lastBalance,
              walletManager.syncState == .synced,
              let wallet = walletManager.moneroWallet else { return }
        if let last = lastNetAmountFill, now.timeIntervalSince(last) < 10 * 60 { return }
        lastNetAmountFill = now
        Task {
            guard let fee = try? await wallet.estimateFee(to: walletManager.primaryAddress, amount: EnvelopeRuntime.xmr(balance)) else { return }
            for var record in store.received where record.needsNetAmount {
                record.netAmount = EnvelopeRecord.net(balance: record.lastBalance ?? 0, fee: EnvelopeRuntime.piconero(fee))
                try? store.save(record)
            }
        }
    }

    /// A sent link's funding block: the last check's, else its funding
    /// transaction's in the active wallet's history. Nil while the funding
    /// is in the pool or another wallet sent it.
    nonisolated static func fundingHeight(of record: EnvelopeRecord, in transactions: [MoneroTransaction]) -> UInt64? {
        if let height = record.fundingHeight, height > 0 { return height }
        guard record.role == .sent, let txid = record.fundingTxid,
              let height = transactions.first(where: { $0.id == txid && $0.type == .outgoing })?.blockHeight,
              height > 0 else { return nil }
        return height
    }

    /// Saves what the active wallet's history tells about its sent links
    /// (see `fundingUpdates`).
    static func reconcileFunding(store: EnvelopeStore, walletManager: WalletManager) {
        let updates = fundingUpdates(
            sent: store.sent,
            activeWalletId: walletManager.activeWallet?.id.uuidString,
            transactions: walletManager.transactions
        )
        for record in updates {
            try? store.save(record)
        }
    }

    /// The sent records the active wallet's history changes:
    /// - a record saved but not marked funded (the app quit during the
    ///   broadcast, or the error came after the node took it) adopts a
    ///   funding transaction the active wallet sent to its address, and
    ///   shows again as a waiting link;
    /// - a record with a funding transaction is never Not funded;
    /// - a mined funding gives its block, where the envelope's scan must
    ///   start.
    nonisolated static func fundingUpdates(
        sent: [EnvelopeRecord],
        activeWalletId: String?,
        transactions: [MoneroTransaction]
    ) -> [EnvelopeRecord] {
        sent.compactMap { original in
            guard original.role == .sent else { return nil }
            var record = original
            // Only the wallet that funded it can hold the funding.
            let fromActiveWallet = record.walletId == nil || record.walletId == activeWalletId
            if record.fundingTxid == nil, fromActiveWallet,
               record.status == .created || record.status == .notFunded || record.fundingStartedAt != nil,
               let funding = transactions.first(where: { tx in
                   tx.type == .outgoing && tx.status != .failed && tx.destinations.contains { $0.address == record.address }
               }) {
                record.fundingTxid = funding.id
                record.confirmations = funding.confirmations
            }
            record.status = EnvelopeStatusRules.reconciled(record.status, role: .sent, fundingTxid: record.fundingTxid)
            if record.fundingHeight == nil {
                record.fundingHeight = fundingHeight(of: record, in: transactions)
            }
            return record == original ? nil : record
        }
    }
}

// MARK: - Link detail

/// One link: its status, amount, transactions and actions. Opened from the
/// link's transactions in Activity.
struct PaymentLinkDetailView: View {
    let recordId: String
    var role: EnvelopeRecord.Role = .sent

    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @ObservedObject private var store = EnvelopeStore.shared
    @State private var showRename = false
    @State private var noteDraft = ""
    /// Reclaim and Claim open their sheet here, not through the app root:
    /// this screen can sit inside Send or a transaction sheet.
    @State private var claimPresentation: PaymentLinksCoordinator.Presentation?
    /// The dashboard and Activity's Links filter check every link: a sent
    /// link looks at its envelope here too, so a claim shows and Reclaim opens.
    @StateObject private var checker = PaymentLinksStatusChecker()
    @State private var isOnScreen = false

    private var record: EnvelopeRecord? { store.record(id: recordId, role: role) }

    var body: some View {
        Group {
            if let record {
                if record.role == .received {
                    receivedContent(record)
                } else {
                    content(record)
                }
            } else {
                PaymentLinkMessageView(systemImage: "link", tint: .gray, title: String(localized: "This link was removed."))
            }
        }
        .navigationTitle("Payment Link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isOnScreen = true
            checkSentLink()
        }
        .onDisappear {
            isOnScreen = false
            checker.stop()
        }
        // A pending link can reach the unlock depth while this screen is open.
        .onChange(of: reachedUnlockDepth) { _, reached in
            if reached, isOnScreen { checkSentLink() }
        }
        .sheet(item: $claimPresentation) { presentation in
            PaymentLinkClaimSheet(presentation: presentation)
                .environmentObject(walletManager)
        }
        .alert("Name this link", isPresented: $showRename) {
            TextField(record?.number.map(EnvelopeRecord.linkName) ?? "", text: $noteDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                try? store.setNote(noteDraft, id: recordId, role: role)
            }
        } message: {
            Text("Only this iPhone keeps the note.")
        }
    }

    /// The link's name over its amount, as a card shows a payment.
    private func hero(_ record: EnvelopeRecord, amount: UInt64?, display: PaymentLinkDisplay, showsReadyTime: Bool) -> some View {
        VStack(spacing: 6) {
            Text(record.displayName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let amount {
                Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(amount))) XMR")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            PaymentLinkStatusChip(display: display)
            // Pending is under 10 confirmations: at 10 the link reads Ready.
            if showsReadyTime {
                Text("Ready in about \(max(1, EnvelopeStatusRules.minutesUntilReady(confirmations: display.confirmations ?? 0))) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// The note; a tap renames the link.
    private func noteRow(_ record: EnvelopeRecord) -> some View {
        let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNote = !(note ?? "").isEmpty
        return Button {
            noteDraft = note ?? ""
            showRename = true
        } label: {
            HStack {
                // Concrete colours: a Button would tint hierarchical ones.
                Text("Note")
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text(hasNote ? (note ?? "") : String(localized: "Add"))
                    .foregroundStyle(hasNote ? Color.primary : Color(uiColor: .tertiaryLabel))
                    .lineLimit(1)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
            .listRowDisclosure()
        }
        .accessibilityLabel(hasNote ? Text("Note, \(note ?? "")") : Text("Note, none"))
        .accessibilityHint("Renames the link")
    }

    /// An amount with its value now under it. The total is the label colour
    /// and semibold, its amount in brand.
    private func amountRow(_ title: String, _ xmr: Decimal, isTotal: Bool = false) -> some View {
        let amount = "\(XMRFormatter.format(xmr)) XMR"
        let fiat = priceService.formatFiatValue(xmr)
        return HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(isTotal ? Color.primary : Color.secondary)
                .fontWeight(isTotal ? .semibold : .regular)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount)
                    .fontWeight(isTotal ? .semibold : .regular)
                    .foregroundStyle(isTotal ? Color.brand : Color.primary)
                    .monospacedDigit()
                if let fiat {
                    Text("≈ \(fiat)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, amount, fiat.map { String(localized: "about \($0)") }].compactMap { $0 }.joined(separator: ", "))
    }

    /// The funding transaction's network fee, when this wallet has it.
    private func networkFee(_ record: EnvelopeRecord) -> Decimal? {
        guard let txid = record.fundingTxid,
              let transaction = walletManager.transactions.first(where: { $0.id == txid && $0.type == .outgoing }),
              transaction.fee > 0 else { return nil }
        return transaction.fee
    }

    private func checkSentLink() {
        guard role == .sent else { return }
        checker.start(walletManager: walletManager, store: store, only: recordId)
    }

    private var reachedUnlockDepth: Bool {
        guard role == .sent, let record, record.status == .pending else { return false }
        return (display(record).confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock
    }

    private func content(_ record: EnvelopeRecord) -> some View {
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        let networkFee = networkFee(record)
        let reserve = record.feeReserve.map(EnvelopeRuntime.xmr)
        return List {
            Section {
                hero(record, amount: record.amount, display: display,
                     showsReadyTime: display.status == .pending && !display.isExpired)
            }

            Section {
                noteRow(record)
                detailRow(String(localized: "Created"), record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let expiryDate = record.expiryDate {
                    detailRow(String(localized: "Expires"), expiryDate.formatted(date: .abbreviated, time: .omitted))
                }
                // What left the wallet: the amount, the network fee and the
                // claim fee reserve. Only here; rows show the amount alone.
                if let networkFee {
                    amountRow(String(localized: "Network fee"), networkFee)
                }
                if let reserve {
                    amountRow(String(localized: "Claim fee reserve"), reserve)
                }
                if let networkFee {
                    amountRow(String(localized: "Total"), EnvelopeRuntime.xmr(record.amount) + (reserve ?? 0) + networkFee, isTotal: true)
                }
                if let txid = record.fundingTxid {
                    transactionRow(String(localized: "Funding transaction"), txid: txid, incoming: false)
                }
                if let txid = record.settleTxid {
                    transactionRow(String(localized: "Reclaim transaction"), txid: txid, incoming: true)
                }
            }

            let actions = PaymentLinkDetailAction.actions(for: record, display: display)
            if record.status.isSettled, record.link != nil {
                Section {
                    Button("Check link") {
                        claimPresentation = .init(id: record.id, kind: .own)
                    }
                }
            }
            if !actions.isEmpty {
                Section {
                    ForEach(actions, id: \.self) { action in
                        switch action {
                        case .share: shareButton(record)
                        case .reclaim: reclaimButton(record, enabled: display.canReclaim)
                        case .claim: EmptyView()
                        }
                    }
                } footer: {
                    if display.status == .pending && !display.isExpired {
                        Text("Reclaim opens when the link is ready, after 10 confirmations.")
                    }
                }
            }
        }
    }

    private func shareButton(_ record: EnvelopeRecord) -> some View {
        Group {
            if record.link != nil {
                PaymentLinkShareButton(record: record) {
                    Label("Share again", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.brand)
                }
                .accessibilityLabel("Share the link again")
            }
        }
    }

    private func reclaimButton(_ record: EnvelopeRecord, enabled: Bool) -> some View {
        Button {
            claimPresentation = .init(id: record.id, kind: .own)
        } label: {
            Label("Reclaim", systemImage: "arrow.uturn.backward")
                .foregroundStyle(enabled ? Color.brand : Color.gray)
                .fontWeight(display(record).isExpired ? .semibold : .regular)
        }
        .disabled(!enabled)
        .accessibilityLabel("Reclaim the money")
        .accessibilityHint(enabled ? "Moves the money in this link back to your wallet" : "Available after 10 confirmations")
    }

    private func display(_ record: EnvelopeRecord) -> PaymentLinkDisplay {
        PaymentLinkDisplay(record: record, walletManager: walletManager)
    }

    /// A transaction row; it opens the transaction when this wallet has it.
    @ViewBuilder
    private func transactionRow(_ title: String, txid: String, incoming: Bool) -> some View {
        if let transaction = walletManager.transactions.first(where: { $0.id == txid && ($0.type == .incoming) == incoming }) {
            NavigationLink {
                TransactionDetailView(transaction: transaction)
            } label: {
                detailRow(title, ReceiveAddressLogic.shortAddress(txid), mono: true)
            }
            .accessibilityHint("Shows the transaction")
        } else {
            detailRow(title, ReceiveAddressLogic.shortAddress(txid), mono: true)
        }
    }

    // MARK: - Received link

    private func receivedContent(_ record: EnvelopeRecord) -> some View {
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        let amount = record.settledAmount ?? record.claimAmount
        let canClaim = PaymentLinkDetailAction.actions(for: record, display: display).contains(.claim)
        return List {
            Section {
                hero(record, amount: amount, display: display,
                     showsReadyTime: display.status == .pending && (display.confirmations ?? 0) < EnvelopeLink.confirmationsToUnlock)
            }

            Section {
                noteRow(record)
                detailRow(String(localized: "Received"), record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if canClaim, let expiryDate = record.expiryDate {
                    detailRow(String(localized: "Claim by"), expiryDate.formatted(date: .abbreviated, time: .omitted))
                }
                if let txid = record.settleTxid {
                    transactionRow(String(localized: "Claim transaction"), txid: txid, incoming: true)
                }
                if record.settleTxid != nil, let wallet = record.walletName, !wallet.isEmpty {
                    detailRow(String(localized: "Claimed to"), wallet)
                }
            }

            if canClaim {
                Section {
                    Button {
                        claimPresentation = .init(id: record.id, kind: .claim)
                    } label: {
                        Label(record.status.isSettled ? "Check link" : "Claim", systemImage: "arrow.down.left")
                            .foregroundStyle(.brand)
                    }
                    .accessibilityLabel("Claim the money")
                    .accessibilityHint("Opens the link and claims it when it is ready")
                } footer: {
                    if display.status == .pending {
                        Text("Claim opens when the link is ready, after 10 confirmations.")
                    }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// What a link's detail offers. There is no Retry and no Remove: a link
/// with a funding transaction waits for it, and a link's secret stays with
/// its record until Remove All.
enum PaymentLinkDetailAction: Hashable {
    case share
    case reclaim
    case claim

    /// A sent link with a funding transaction (Pending or Ready, whatever
    /// the last scan said) can be shared again and reclaimed; Reclaim comes
    /// first once it expired. A sent link without one, or one that was
    /// claimed or reclaimed, offers nothing. A received link offers Claim
    /// while its secret is available, including a fresh check after a claim.
    static func actions(for record: EnvelopeRecord, display: PaymentLinkDisplay) -> [PaymentLinkDetailAction] {
        let hasLink = record.link != nil
        switch record.role {
        case .received:
            // A fresh scan can recover a dropped claim or funding left locked
            // by an earlier sweep. Retained secrets must remain usable.
            return hasLink ? [.claim] : []
        case .sent:
            // No Share while no funding is known: the envelope may be empty.
            guard record.fundingTxid != nil, display.status == .pending || display.status == .ready else { return [] }
            let share: [PaymentLinkDetailAction] = hasLink ? [.share] : []
            return display.isExpired ? [.reclaim] + share : share + [.reclaim]
        }
    }
}
