import SwiftUI

struct NumericKeypad: View {
    @Binding var text: String
    var maxDecimalPlaces: Int = 12
    /// The height of a row of keys, glass included, on a short screen. Nil:
    /// the 60pt iPhone keys.
    var rowHeight: CGFloat? = nil

    /// Shorter keys sit closer together.
    private var spacing: CGFloat { rowHeight == nil ? 12 : 8 }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { key in
                        KeypadButton(key: key, isCompact: rowHeight != nil) {
                            handleKey(key)
                        }
                    }
                }
                .frame(height: rowHeight)
            }
        }
    }

    private func handleKey(_ key: String) {
        HapticFeedback.shared.softTick()

        switch key {
        case "⌫":
            if !text.isEmpty {
                text.removeLast()
            }

        case ".":
            if !text.contains(".") {
                if text.isEmpty {
                    text = "0."
                } else {
                    text.append(".")
                }
            }

        default: // digit
            // Prevent leading zeros (except "0.")
            if text == "0" && key != "." {
                text = key
                return
            }

            // Enforce decimal place limit
            if let dotIndex = text.firstIndex(of: ".") {
                let decimals = text.distance(from: dotIndex, to: text.endIndex) - 1
                if decimals >= maxDecimalPlaces {
                    return
                }
            }

            text.append(key)
        }
    }
}

private struct KeypadButton: View {
    let key: String
    /// The key fills its row: the row sets the height, the digit is smaller.
    var isCompact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(isCompact ? .title3 : .title2)
                } else {
                    Text(key)
                        .font((isCompact ? Font.title2 : .title).weight(.medium).monospacedDigit())
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: isCompact ? .infinity : nil)
            .frame(height: isCompact ? nil : 60)
        }
        .glassButtonStyle()
        .accessibilityLabel(key == "⌫" ? String(localized: "Delete") : key == "." ? String(localized: "Decimal point") : key)
    }
}
