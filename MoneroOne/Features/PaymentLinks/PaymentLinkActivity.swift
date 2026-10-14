import SwiftUI

/// Payment links in Activity: which wallet transactions belong to a link,
/// how their rows read, and the received links that wait at the top.
///
/// Rules (Android uses the same ones). A transaction matches a link record
/// on this device by txid:
/// - sent record, outgoing tx == `fundingTxid` → "Payment link" (funding)
/// - sent record, incoming tx == `settleTxid` → "Link reclaimed"
/// - received record, incoming tx == `settleTxid` → "Claimed link"
/// Every other transaction keeps "Received" / "Sent". A link row shows a
/// link glyph in the disc of its direction and opens the link's detail.
struct PaymentLinkActivity: Equatable {
    enum Kind: Equatable {
        /// Our send that put money in a link we made.
        case funding
        /// Our sweep that took a sent link's money back.
        case reclaim
        /// Our sweep that claimed a received link.
        case claim
    }

    let kind: Kind
    let record: EnvelopeRecord

    static func match(transactionId: String, isIncoming: Bool, records: [EnvelopeRecord]) -> PaymentLinkActivity? {
        for record in records {
            switch record.role {
            case .sent:
                if !isIncoming, record.fundingTxid == transactionId {
                    return PaymentLinkActivity(kind: .funding, record: record)
                }
                if isIncoming, record.settleTxid == transactionId {
                    return PaymentLinkActivity(kind: .reclaim, record: record)
                }
            case .received:
                if isIncoming, record.settleTxid == transactionId {
                    return PaymentLinkActivity(kind: .claim, record: record)
                }
            }
        }
        return nil
    }

    @MainActor
    static func match(_ transaction: MoneroTransaction, store: EnvelopeStore = .shared) -> PaymentLinkActivity? {
        match(transactionId: transaction.id, isIncoming: transaction.type == .incoming, records: store.records)
    }

    var title: String {
        switch kind {
        case .funding: return String(localized: "Payment link", comment: "Activity row title: a send that put money in a payment link")
        case .reclaim: return String(localized: "Link reclaimed", comment: "Activity row title: money taken back from your own payment link")
        case .claim: return String(localized: "Claimed link", comment: "Activity row title: money claimed from a payment link someone sent you")
        }
    }

    /// Funding rows only: where the link stands, in place of the date.
    @MainActor
    func statusLine(walletManager: WalletManager) -> String? {
        guard kind == .funding else { return nil }
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        return Self.fundingStatusLine(status: display.status, isExpired: display.isExpired, confirmations: display.confirmations)
    }

    /// The row is the funding transaction itself, so "not funded" never
    /// shows: until a check sees the money, the link waits to be claimed.
    static func fundingStatusLine(status: EnvelopeStatus, isExpired: Bool, confirmations: Int?) -> String {
        switch status {
        case .claimed: return String(localized: "Claimed", comment: "Activity row: the payment link was claimed")
        case .reclaimed: return String(localized: "Reclaimed", comment: "Activity row: you took the payment link's money back")
        default: break
        }
        if isExpired { return String(localized: "Expired", comment: "Activity row: the payment link expired") }
        if status == .ready || (confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock {
            return String(localized: "Ready to claim", comment: "Activity row: the payment link can be claimed now")
        }
        return String(localized: "Waiting to be claimed", comment: "Activity row: the payment link is not claimed yet")
    }

    /// VoiceOver: "Payment link, minus 0.5 XMR, waiting to be claimed,
    /// 2 hr. ago, Confirmed".
    static func accessibilityLabel(
        title: String,
        isIncoming: Bool,
        amountSpoken: String,
        statusLine: String?,
        date: String,
        transactionStatus: String
    ) -> String {
        let amount = isIncoming
            ? String(localized: "plus \(amountSpoken)", comment: "VoiceOver: amount coming in")
            : String(localized: "minus \(amountSpoken)", comment: "VoiceOver: amount going out")
        return [title, amount, statusLine, date, transactionStatus].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Transaction rows

/// Title, glyph and second line of one Activity row: the link's when the
/// transaction belongs to a payment link, else the usual ones.
struct ActivityRowText {
    let title: String
    let systemImage: String
    let subtitle: String
    let accessibilityLabel: String

    @MainActor
    init(transaction: MoneroTransaction, date: String, amount: TransactionAmountText, walletManager: WalletManager, store: EnvelopeStore) {
        let isIncoming = transaction.type == .incoming
        if let link = PaymentLinkActivity.match(transaction, store: store) {
            let statusLine = link.statusLine(walletManager: walletManager)
            title = link.title
            systemImage = "link"
            subtitle = statusLine ?? date
            accessibilityLabel = PaymentLinkActivity.accessibilityLabel(
                title: link.title,
                isIncoming: isIncoming,
                amountSpoken: amount.spoken,
                statusLine: statusLine,
                date: date,
                transactionStatus: transaction.displayStatusText
            )
        } else {
            title = isIncoming ? String(localized: "Received") : String(localized: "Sent")
            systemImage = isIncoming ? "arrow.down.left" : "arrow.up.right"
            subtitle = date
            accessibilityLabel = "\(title) \(amount.spoken), \(date), \(transaction.displayStatusText)"
        }
    }
}

/// What a tap on an Activity row opens: the link's detail for a payment
/// link transaction, else the transaction.
struct ActivityDetailView: View {
    let transaction: MoneroTransaction
    @ObservedObject private var store = EnvelopeStore.shared

    var body: some View {
        if let link = PaymentLinkActivity.match(transaction, store: store) {
            PaymentLinkDetailView(recordId: link.record.id, role: link.record.role)
        } else {
            TransactionDetailView(transaction: transaction)
        }
    }
}

/// Transaction detail: a "Payment link" row with the link's status chip, for a transaction that
/// belongs to a link. Nothing for any other transaction.
struct PaymentLinkTransactionRow: View {
    let transaction: MoneroTransaction
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = EnvelopeStore.shared

    var body: some View {
        if let link = PaymentLinkActivity.match(transaction, store: store) {
            let display = PaymentLinkDisplay(record: link.record, walletManager: walletManager)
            HStack {
                Text("Payment link")
                Spacer()
                PaymentLinkStatusChip(display: display)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Payment link: \(display.label)", comment: "VoiceOver: transaction detail row, the payment link's status"))
        }
    }
}

// MARK: - Received links waiting at the top of Activity

/// Received links not claimed yet, pinned above the transactions until
/// they are claimed. Their state comes from the record and the active
/// wallet's daemon height, so the list never opens an envelope (that
/// stops the active wallet); a tap opens the claim sheet, which does.
enum PendingPaymentLinks {
    enum State: Equatable {
        /// Saved, never checked (the claim sheet closed before its check).
        case unchecked
        /// Checked: no money in the link yet.
        case noMoney
        /// Funded, not unlocked: about this many minutes left.
        case waiting(minutes: Int)
        /// 10 confirmations or more, as far as this device knows.
        case ready
    }

    /// Newest first. Only links this device can still claim (it has the
    /// secret) and that are not settled.
    @MainActor
    static func records(in store: EnvelopeStore) -> [EnvelopeRecord] {
        store.received.filter { !$0.status.isSettled && $0.link != nil }
    }

    /// Confirmations come from the funding height the last check saw and
    /// the active wallet's daemon height (2-minute blocks). Without a
    /// height (the funding was still in the mempool), the count of the last
    /// check less the minutes since.
    static func state(of record: EnvelopeRecord, daemonHeight: UInt64, now: Date = Date()) -> State {
        let unlock = EnvelopeLink.confirmationsToUnlock
        switch record.status {
        case .created, .claimed, .reclaimed:
            return .unchecked
        case .notFunded:
            return .noMoney
        case .ready:
            return .ready
        case .pending:
            if let height = record.fundingHeight, daemonHeight > height {
                let confirmations = Int(daemonHeight - height)
                if confirmations >= unlock { return .ready }
                return .waiting(minutes: max(1, EnvelopeStatusRules.minutesUntilReady(confirmations: confirmations)))
            }
            let minutes = EnvelopeStatusRules.minutesUntilReady(confirmations: record.confirmations ?? 0)
            let elapsed = record.lastCheckedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) } ?? 0
            if elapsed >= minutes { return .ready }
            return .waiting(minutes: max(1, minutes - elapsed))
        }
    }

    static func label(for state: State) -> String {
        switch state {
        case .unchecked: return String(localized: "Tap to check", comment: "Pinned payment link row: the link was not checked yet")
        case .noMoney: return String(localized: "No money yet", comment: "Pinned payment link row: the link holds no money yet")
        case .waiting(let minutes): return String(localized: "Ready in about \(minutes) min")
        case .ready: return String(localized: "Ready to claim")
        }
    }
}

/// One received link at the top of Activity: "Payment link", its state,
/// the amount when known, and a Claim chip once it is ready. A tap opens
/// the claim sheet; when ready, the sheet claims as soon as its check
/// confirms it.
struct PendingPaymentLinkRow: View {
    enum Style {
        /// A glass card, as on the Wallet tab and the iPad panel.
        case card(padding: CGFloat)
        /// A plain list row, as in All Transactions.
        case listRow
    }

    let record: EnvelopeRecord
    let style: Style
    @EnvironmentObject var walletManager: WalletManager

    private var state: PendingPaymentLinks.State {
        PendingPaymentLinks.state(of: record, daemonHeight: walletManager.daemonHeight)
    }

    private var amountText: String? {
        record.knownAmount.map { "+\(XMRFormatter.format(EnvelopeRuntime.xmr($0)))" }
    }

    var body: some View {
        let state = self.state
        switch style {
        case .card(let padding):
            Button { open(state) } label: {
                content(state, iconShape: .disc)
                    .padding(padding)
            }
            .glassButtonStyle()
            .modifier(RowAccessibility(text: accessibilityText(state), hint: accessibilityHint(state), id: record.id))
        case .listRow:
            Button { open(state) } label: {
                content(state, iconShape: .tile)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(RowAccessibility(text: accessibilityText(state), hint: accessibilityHint(state), id: record.id))
        }
    }

    private enum IconShape { case disc, tile }

    private func content(_ state: PendingPaymentLinks.State, iconShape: IconShape) -> some View {
        HStack(spacing: 12) {
            icon(iconShape)

            VStack(alignment: .leading, spacing: iconShape == .disc ? 2 : 4) {
                Text("Payment link")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .fixedSize()
                    .foregroundStyle(.primary)
                Text(PendingPaymentLinks.label(for: state))
                    .font(.caption)
                    .foregroundStyle(state == .ready ? Color.green : Color.secondary)
                    .monospacedDigit()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let amountText {
                    Text(amountText)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                if state == .ready {
                    Text("Claim")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.brand)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.brand.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .layoutPriority(1)

            if iconShape == .disc {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func icon(_ shape: IconShape) -> some View {
        switch shape {
        case .disc:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .accessibilityHidden(true)
        case .tile:
            Image(systemName: "link")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.15))
                .cornerRadius(8)
                .accessibilityHidden(true)
        }
    }

    private func open(_ state: PendingPaymentLinks.State) {
        PaymentLinksCoordinator.shared.present(record, autoClaim: state == .ready)
    }

    private func accessibilityText(_ state: PendingPaymentLinks.State) -> String {
        let amount = record.knownAmount.map {
            String(localized: "plus \(XMRFormatter.format(EnvelopeRuntime.xmr($0))) XMR", comment: "VoiceOver: amount coming in")
        }
        return [String(localized: "Payment link"), amount, PendingPaymentLinks.label(for: state)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func accessibilityHint(_ state: PendingPaymentLinks.State) -> String {
        if state == .ready, let wallet = walletManager.activeWallet?.name, !wallet.isEmpty {
            return String(localized: "Claims the money to \(wallet)")
        }
        return String(localized: "Opens the link to claim it")
    }

    private struct RowAccessibility: ViewModifier {
        let text: String
        let hint: String
        let id: String

        func body(content: Content) -> some View {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
                .accessibilityHint(hint)
                .accessibilityIdentifier("activity.paymentLink.\(id)")
        }
    }
}
