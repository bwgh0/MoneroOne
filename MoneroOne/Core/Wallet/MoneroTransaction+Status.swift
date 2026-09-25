import SwiftUI

extension MoneroTransaction {
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
            return .orange
        } else if confirmations < 10 {
            return .orange
        } else {
            return .green
        }
    }
}
