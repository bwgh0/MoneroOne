import SwiftUI

/// Payment links in Activity: which wallet transactions belong to a link
/// and how their rows read.
///
/// Rules (Android uses the same ones). A transaction matches a link record
/// on this device by txid:
/// - sent record, outgoing tx == `fundingTxid` → funding ("Sent by Link")
/// - sent record, incoming tx == `settleTxid` → reclaim ("Reclaimed by Link")
/// - received record, incoming tx == `settleTxid` → claim ("Received by Link")
/// A link row reads like any other row: the direction's disc with a link
/// badge, the link's name, the date, one amount. A funding row shows the
/// link's amount and state (Waiting, Ready, Claimed, Reclaimed, Expired);
/// reclaim and claim rows show the transaction's. The kind ("Sent by
/// Link") is spoken only. A tap opens the link's detail. A link sent to us
/// that waits to be claimed gets the same row (`PaymentLinkToClaimRow`).
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
    static func match(_ transaction: MoneroTransaction, store: EnvelopeStore) -> PaymentLinkActivity? {
        match(transactionId: transaction.id, isIncoming: transaction.type == .incoming, records: store.records)
    }

    /// What kind of link transaction it is, spoken by VoiceOver: the
    /// row's title is the link's name.
    var title: String {
        switch kind {
        case .funding: return String(localized: "Sent by Link", comment: "VoiceOver, Activity row: a send that put money in a payment link")
        case .reclaim: return String(localized: "Reclaimed by Link", comment: "VoiceOver, Activity row: money taken back from your own payment link")
        case .claim: return String(localized: "Received by Link", comment: "VoiceOver, Activity row: money claimed from a payment link someone sent you")
        }
    }

    /// The amount the row shows. A funding transaction also carries the
    /// claim fee reserve; its row shows the link's amount, what the
    /// recipient gets, as the detail and the balance card do. Reclaim and
    /// claim rows show what came in.
    func rowAmount(transactionAmount: Decimal) -> Decimal {
        kind == .funding ? EnvelopeRuntime.xmr(record.amount) : transactionAmount
    }

    /// A funding row: where the link stands, in place of the transaction's
    /// status. Nil for reclaim and claim rows, and for a funding
    /// transaction that failed: those show the transaction's status.
    @MainActor
    func rowStatus(transactionFailed: Bool, walletManager: WalletManager?) -> PaymentLinkRowStatus? {
        guard kind == .funding, !transactionFailed else { return nil }
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        return .funding(status: display.status, isExpired: display.isExpired, confirmations: display.confirmations)
    }

    /// VoiceOver: "Sent by Link, Dinner, minus 0.02 XMR, Waiting, Oct 16,
    /// 2026 at 9:41 AM".
    static func accessibilityLabel(
        kind: String,
        name: String,
        isIncoming: Bool,
        amountSpoken: String?,
        status: String,
        date: String
    ) -> String {
        let amount = amountSpoken.map {
            isIncoming
                ? String(localized: "plus \($0)", comment: "VoiceOver: amount coming in")
                : String(localized: "minus \($0)", comment: "VoiceOver: amount going out")
        }
        return [kind, name, amount, status, date].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Where a payment link stands, in the status spot of its Activity row.
enum PaymentLinkRowStatus: Equatable {
    /// Funded, under 10 confirmations, or not seen funded yet.
    case waiting
    /// Sent: 10 confirmations, the recipient can claim it.
    case ready
    case claimed
    case reclaimed
    /// Sent, past its expiry and still holding the money; or sent to us,
    /// and no money came in its days to claim.
    case expired
    /// Sent to us: we can claim it now.
    case readyToClaim

    /// A funding row. The row is the funding transaction, so "not funded"
    /// never shows: until a check sees the money, the link is waiting.
    static func funding(status: EnvelopeStatus, isExpired: Bool, confirmations: Int?) -> PaymentLinkRowStatus {
        switch status {
        case .claimed: return .claimed
        case .reclaimed: return .reclaimed
        default: break
        }
        if isExpired { return .expired }
        if status == .ready || (confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock { return .ready }
        return .waiting
    }

    /// A link sent to us, not claimed yet.
    static func toClaim(_ state: PendingPaymentLinks.State) -> PaymentLinkRowStatus {
        switch state {
        case .ready: return .readyToClaim
        case .expired: return .expired
        default: return .waiting
        }
    }

    var text: String {
        switch self {
        case .waiting: return String(localized: "Waiting", comment: "Activity row: the payment link is not claimed yet, or not ready")
        case .ready: return String(localized: "Ready", comment: "Activity row: the payment link can be claimed now")
        case .claimed: return String(localized: "Claimed", comment: "Activity row: the payment link was claimed")
        case .reclaimed: return String(localized: "Reclaimed", comment: "Activity row: you took the payment link's money back")
        case .expired: return String(localized: "Expired", comment: "Activity row: the payment link expired")
        case .readyToClaim: return String(localized: "Ready to claim")
        }
    }

    /// Pending in brand, done in green, Reclaimed gray, Expired a yellow
    /// dot (a caution: its text stays in the label colour).
    var dotColor: Color {
        switch self {
        case .waiting: return .brand
        case .ready, .claimed, .readyToClaim: return .green
        case .reclaimed: return .gray
        case .expired: return .yellow
        }
    }

    var textColor: Color {
        self == .expired ? .primary : dotColor
    }
}

/// The status spot of a link's Activity row: a dot and the state.
struct PaymentLinkStatusLabel: View {
    let status: PaymentLinkRowStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 6, height: 6)
            Text(status.text)
                .font(.caption2)
                .foregroundStyle(status.textColor)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Link badge

extension View {
    /// The link badge on an Activity row's direction disc: a small circle
    /// at the bottom-right, a light tint of `hue` with the link glyph in
    /// it, set in a ring cut out of the disc so the row shows through.
    func paymentLinkBadge(_ hue: Color, isShown: Bool = true) -> some View {
        modifier(PaymentLinkBadge(hue: hue, isShown: isShown))
    }
}

private struct PaymentLinkBadge: ViewModifier {
    let hue: Color
    let isShown: Bool

    /// From the mockup's 3x frames: a 16 pt badge, a 1.5 pt ring, 5 pt
    /// past the disc's corner.
    private let size: CGFloat = 16
    private let ring: CGFloat = 1.5
    private let overhang: CGFloat = 5

    func body(content: Content) -> some View {
        if isShown {
            content
                .mask {
                    ZStack(alignment: .bottomTrailing) {
                        Rectangle()
                        Circle()
                            .frame(width: size + 2 * ring, height: size + 2 * ring)
                            .offset(x: overhang + ring, y: overhang + ring)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hue)
                        .frame(width: size, height: size)
                        .background(Circle().fill(hue.opacity(0.15)))
                        .offset(x: overhang, y: overhang)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

// MARK: - Transaction rows

/// Title, glyph, second line, amount and status of one Activity row: the
/// link's when the transaction belongs to a payment link, else the usual
/// ones.
struct ActivityRowText {
    /// The link's name, or "Received" / "Sent".
    let title: String
    /// The direction's arrow, for link rows too.
    let systemImage: String
    /// A link row: the disc gets the link badge.
    let showsLinkBadge: Bool
    /// The date, on every row.
    let subtitle: String
    /// The amount the row shows (`PaymentLinkActivity.rowAmount`).
    let xmr: Decimal
    /// A funding row's link state, shown in place of the transaction's
    /// status.
    let linkStatus: PaymentLinkRowStatus?
    private let link: PaymentLinkActivity?
    private let isIncoming: Bool
    private let transactionStatus: String

    @MainActor
    init(transaction: MoneroTransaction, date: String, walletManager: WalletManager, store: EnvelopeStore) {
        isIncoming = transaction.type == .incoming
        link = PaymentLinkActivity.match(transaction, store: store)
        systemImage = isIncoming ? "arrow.down.left" : "arrow.up.right"
        subtitle = date
        transactionStatus = transaction.displayStatusText
        if let link {
            title = link.record.displayName
            showsLinkBadge = true
            xmr = link.rowAmount(transactionAmount: transaction.amount)
            linkStatus = link.rowStatus(transactionFailed: transaction.status == .failed, walletManager: walletManager)
        } else {
            title = isIncoming ? String(localized: "Received") : String(localized: "Sent")
            showsLinkBadge = false
            xmr = transaction.amount
            linkStatus = nil
        }
    }

    /// Link rows keep the words VoiceOver said before the names: "Sent by
    /// Link, Dinner, minus 0.02 XMR, Waiting, Oct 16, 2026 at 9:41 AM".
    func accessibilityLabel(amount: TransactionAmountText) -> String {
        guard let link else {
            return "\(title) \(amount.spoken), \(subtitle), \(transactionStatus)"
        }
        return PaymentLinkActivity.accessibilityLabel(
            kind: link.title,
            name: title,
            isIncoming: isIncoming,
            amountSpoken: amount.spoken,
            status: linkStatus?.text ?? transactionStatus,
            date: subtitle
        )
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

// MARK: - Received links waiting to be claimed

/// Received links not claimed yet: the balance card's Claim line and the
/// rows at the top of Activity's Links filter. Their state comes from the
/// record and the active wallet's daemon height, so neither opens an
/// envelope (that stops the active wallet); the claim sheet does.
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
        /// No money arrived in its days to claim
        /// (`EnvelopeRecord.isReceivedExpired`): History, as Expired.
        case expired
    }

    /// Newest first. Only links this device can still claim (it has the
    /// secret) and that are not settled.
    @MainActor
    static func records(in store: EnvelopeStore) -> [EnvelopeRecord] {
        store.received.filter { OpenPaymentLinks.isWaitingToClaim($0) }
    }

    /// Confirmations come from the funding height the last check saw and
    /// the active wallet's daemon height (2-minute blocks). Without a
    /// height (the funding was still in the mempool), the count of the last
    /// check less the minutes since.
    static func state(of record: EnvelopeRecord, daemonHeight: UInt64, now: Date = Date()) -> State {
        if record.isReceivedExpired(now: now) { return .expired }
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
        case .unchecked: return String(localized: "Tap to check", comment: "Payment link sent to you: the link was not checked yet")
        case .noMoney: return String(localized: "No money yet", comment: "Payment link sent to you: the link holds no money yet")
        case .waiting(let minutes): return String(localized: "Ready in about \(minutes) min")
        case .ready: return String(localized: "Ready to claim")
        case .expired: return String(localized: "Expired")
        }
    }
}
