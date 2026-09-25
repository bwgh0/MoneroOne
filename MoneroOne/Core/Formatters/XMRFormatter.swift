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

    /// A short form for a caption under a fiat amount: four decimals, or
    /// four significant digits when the amount is smaller, rounded toward
    /// zero so it never shows more than the real amount.
    /// "0.000580526955" reads "0.0005805"; `format(_:)` keeps every digit.
    static func formatCompact(_ value: Decimal) -> String {
        let tenth = Decimal(sign: .plus, exponent: -1, significand: 1)
        var scaled = abs(value)
        var leadingZeros = 0
        while scaled > 0 && scaled < tenth && leadingZeros < 8 {
            scaled *= 10
            leadingZeros += 1
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = leadingZeros + 4
        formatter.roundingMode = .down
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ","
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}
