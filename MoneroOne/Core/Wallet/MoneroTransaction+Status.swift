import SwiftUI

extension MoneroTransaction {
    /// Display status text based on confirmation count and failed status
    var displayStatusText: String {
        if status == .failed {
            return "Failed"
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
        if confirmations == 0 {
            return .orange
        } else if confirmations < 10 {
            return .orange
        } else {
            return .green
        }
    }
}
