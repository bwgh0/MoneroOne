import Foundation

enum XMRFormatter {
    static func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ","
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}
