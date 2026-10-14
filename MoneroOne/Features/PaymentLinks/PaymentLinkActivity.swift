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
