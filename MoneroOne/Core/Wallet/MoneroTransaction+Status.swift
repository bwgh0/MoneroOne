import SwiftUI

extension MoneroTransaction {
    /// Whether confirmation data is still loading
    var isStatusLoading: Bool {
        confirmations == nil && status != .failed && status != .pending
    }

    /// Display status text based on confirmation count and failed status
    var displayStatusText: String {
        if status == .failed {
            return "Failed"
        }
        guard let confirmations else {
            return "" // Loading — UI shows spinner instead
        }
        if confirmations == 0 {
            return "Pending"
        } else if confirmations < 10 {
            return "Locked"
        } else {
            return "Confirmed"
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
