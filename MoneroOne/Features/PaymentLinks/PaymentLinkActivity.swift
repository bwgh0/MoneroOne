import SwiftUI

/// Payment links in Activity: which wallet transactions belong to a link
/// and how their rows read.
///
/// Rules (Android uses the same ones). A transaction matches a link record
/// on this device by txid:
/// - sent record, outgoing tx == `fundingTxid` → "Sent by Link" (funding)
/// - sent record, incoming tx == `settleTxid` → "Reclaimed by Link"
/// - received record, incoming tx == `settleTxid` → "Received by Link"
/// Every other transaction keeps "Received" / "Sent". A link row shows a
/// link glyph in the disc of its direction and opens the link's detail.
/// Activity's Links filter shows these rows only, under the links sent to
/// us that wait to be claimed (`PaymentLinkToClaimRow`).
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

    var title: String {
        switch kind {
        case .funding: return String(localized: "Sent by Link", comment: "Activity row title: a send that put money in a payment link")
        case .reclaim: return String(localized: "Reclaimed by Link", comment: "Activity row title: money taken back from your own payment link")
        case .claim: return String(localized: "Received by Link", comment: "Activity row title: money claimed from a payment link someone sent you")
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

    /// VoiceOver: "Sent by Link, minus 0.5 XMR, waiting to be claimed,
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
    /// The subtitle is a link's status, not the date. It stays on one
    /// line: the row's even split with the spacer wrapped "Ready to claim".
    let subtitleIsStatus: Bool
    let accessibilityLabel: String

    @MainActor
    init(transaction: MoneroTransaction, date: String, amount: TransactionAmountText, walletManager: WalletManager, store: EnvelopeStore) {
        let isIncoming = transaction.type == .incoming
        if let link = PaymentLinkActivity.match(transaction, store: store) {
            let statusLine = link.statusLine(walletManager: walletManager)
            title = link.title
            systemImage = "link"
            subtitle = statusLine ?? date
            subtitleIsStatus = statusLine != nil
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
            subtitleIsStatus = false
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
    }

    /// Newest first. Only links this device can still claim (it has the
    /// secret) and that are not settled.
    @MainActor
    static func records(in store: EnvelopeStore) -> [EnvelopeRecord] {
        store.received.filter(OpenPaymentLinks.isWaitingToClaim)
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
        case .unchecked: return String(localized: "Tap to check", comment: "Payment link sent to you: the link was not checked yet")
        case .noMoney: return String(localized: "No money yet", comment: "Payment link sent to you: the link holds no money yet")
        case .waiting(let minutes): return String(localized: "Ready in about \(minutes) min")
        case .ready: return String(localized: "Ready to claim")
        }
    }
}
