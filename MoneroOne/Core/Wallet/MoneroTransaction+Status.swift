import SwiftUI

/// The part of a transaction that its row shows and that new blocks change.
/// `MoneroTransaction`'s `==` compares ids only, so SwiftUI kept a row view
/// whose input was only the transaction: its status and ring stayed at the
/// first draw until the list opened again. Row views and lists also take
/// this value, so each new confirmation draws them again.
struct TransactionRowState: Equatable {
    let id: String
    let confirmations: Int?
    let status: MoneroTransaction.TransactionStatus

    init(_ transaction: MoneroTransaction) {
        id = transaction.id
        confirmations = transaction.confirmations
        status = transaction.status
    }
}

extension MoneroTransaction {
    /// What the transaction's row shows that new blocks change.
    var rowState: TransactionRowState { TransactionRowState(self) }

    /// Whether confirmation data is still loading
    var isStatusLoading: Bool {
        confirmations == nil && status != .failed && status != .pending
    }

    /// Display status text based on confirmation count and failed status
    var displayStatusText: String {
        if status == .failed {
            return String(localized: "Failed", comment: "Transaction status")
        }
        guard let confirmations else {
            return "" // Loading — UI shows spinner instead
        }
        if confirmations == 0 {
            return String(localized: "Pending", comment: "Transaction status")
        } else if confirmations < 10 {
            return String(localized: "Locked", comment: "Transaction status: confirmed but not yet spendable")
        } else {
            return String(localized: "Confirmed", comment: "Transaction status")
        }
    }

    /// Display status color based on confirmation count and failed status
    var displayStatusColor: Color {
        if status == .failed {
            return .red
        }
        guard let confirmations else {
            return .secondary
        }
        if confirmations == 0 {
            return .brand
        } else if confirmations < 10 {
            return .brand
        } else {
            return .green
        }
    }
}
