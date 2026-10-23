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

    /// The transaction with its confirmations counted at `daemonHeight`, as
    /// `MoneroWallet.mapTransaction` counts them. The kit reports the
    /// history only when a transaction changes (its first block, its
    /// unlock), so each new block counts the rings again: a mined
    /// transaction with 1 to 9 confirmations. Others stay as they are.
    func counted(at daemonHeight: UInt64) -> MoneroTransaction {
        guard status == .confirmed,
              let confirmations, (1..<ConfirmationRing.target).contains(confirmations),
              let blockHeight, daemonHeight > blockHeight else { return self }
        let count = Int(daemonHeight - blockHeight)
        guard count != confirmations else { return self }
        return MoneroTransaction(
            id: id, type: type, amount: amount, fee: fee, address: address, timestamp: timestamp,
            confirmations: count, status: status, memo: memo, blockHeight: blockHeight,
            destinations: destinations, subaddressIndex: subaddressIndex
        )
    }

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
