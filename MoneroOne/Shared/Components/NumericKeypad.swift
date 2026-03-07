import SwiftUI

struct NumericKeypad: View {
    @Binding var text: String
    var maxDecimalPlaces: Int = 12

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { key in
                        KeypadButton(key: key) {
                            handleKey(key)
                        }
                    }
                }
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.title2)
                } else {
                    Text(key)
                        .font(.title.weight(.medium).monospacedDigit())
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
        }
        .glassButtonStyle()
        .accessibilityLabel(key == "⌫" ? "Delete" : key == "." ? "Decimal point" : key)
    }
}
