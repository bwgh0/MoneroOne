import SwiftUI

struct SendAmountStep: View {
    @Binding var amountString: String
    @Binding var memo: String
    @Binding var isSendingAll: Bool
    let recipientAddress: String
    let unlockedBalance: Decimal
    let priceService: PriceService
    let onContinue: () -> Void

    @State private var showContent = false
    @State private var showMemo = false
    @State private var softwareKeyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 12)

                    // Amount display
                    VStack(spacing: 4) {
                        ZStack {
                            // Hidden input for hardware keyboard support (no software keyboard)
                            HardwareKeyboardInput(
                                text: $amountString,
                                filter: filterDecimalInput
                            )
                            .frame(width: 1, height: 1)
                            .opacity(0.01)

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(amountString.isEmpty ? "0" : amountString)
                                    .font(.system(size: 56, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.4)

                                Text("XMR")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(amountString.isEmpty ? "0" : amountString) XMR")
                        }

                        // Fiat equivalent
                        if let amountDecimal = Decimal(string: amountString),
                           amountDecimal > 0,
                           let fiat = priceService.formatFiatValue(amountDecimal) {
                            Text("≈ \(fiat)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    // Balance row with Paste + Max buttons
                    HStack {
                        Text("Available: \(XMRFormatter.format(unlockedBalance)) XMR")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            pasteAmount()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.caption2)
                                Text("Paste")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .accessibilityLabel("Paste amount from clipboard")

                        Button("Max") {
                            isSendingAll = true
                            amountString = "\(unlockedBalance)"
                            HapticFeedback.shared.softTick()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                        .accessibilityLabel("Send maximum amount")
                    }
                    .padding(.horizontal, 4)

                    // Memo field (collapsible)
                    VStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showMemo.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "note.text")
                                Text(showMemo ? "Hide memo" : "Add memo")
                                    .font(.caption)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .rotationEffect(.degrees(showMemo ? 180 : 0))
                            }
                            .foregroundStyle(.secondary)
                        }

                        if showMemo {
                            TextField("Add a note", text: $memo)
                                .font(.subheadline)
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }
            .scrollDismissesKeyboard(.immediately)

            // Keypad + continue
            VStack(spacing: 12) {
                if !softwareKeyboardVisible {
                    NumericKeypad(text: $amountString)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Text("Continue")
                            .font(.callout.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(canContinue ? .orange : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .disabled(!canContinue)
                .accessibilityLabel("Continue")
                .accessibilityHint(canContinue ? "Proceed to review transaction" : "Enter a valid amount first")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Send to \(formatAddress(recipientAddress))")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: amountString) { newValue in
            // Clear send-all when user edits amount
            if isSendingAll {
                let maxStr = "\(unlockedBalance)"
                if newValue != maxStr {
                    isSendingAll = false
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: softwareKeyboardVisible)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
            if !memo.isEmpty { showMemo = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            softwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            softwareKeyboardVisible = false
        }
    }

    private var canContinue: Bool {
        guard let amount = Decimal(string: amountString),
              amount > 0,
              amount <= unlockedBalance else {
            return false
        }
        return true
    }

    private func pasteAmount() {
        guard let clipboard = UIPasteboard.general.string else { return }
        let filtered = filterDecimalInput(clipboard.trimmingCharacters(in: .whitespacesAndNewlines))
        if !filtered.isEmpty {
            amountString = filtered
            HapticFeedback.shared.softTick()
        }
    }

    private func filterDecimalInput(_ input: String) -> String {
        var hasDecimal = false
        var result = ""

        for char in input {
            if char.isNumber {
                result.append(char)
            } else if (char == "." || char == ",") && !hasDecimal {
                hasDecimal = true
                result.append(".")
            }
        }

        // Prevent leading zeros (allow "0." though)
        if result.count > 1 && result.first == "0" && result.dropFirst().first != "." {
            result = String(result.drop(while: { $0 == "0" }))
            if result.isEmpty || result.first == "." {
                result = "0" + result
            }
        }

        // Limit decimal places to 12
        if let dotIndex = result.firstIndex(of: ".") {
            let afterDecimal = result.distance(from: dotIndex, to: result.endIndex) - 1
            if afterDecimal > 12 {
                result = String(result.prefix(result.count - (afterDecimal - 12)))
            }
        }

        return result
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 16 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(4))"
    }
}

// MARK: - Hardware Keyboard Input (no software keyboard)

/// A UIViewRepresentable that accepts hardware keyboard input without showing the software keyboard.
/// Uses `inputView = UIView()` to suppress the on-screen keyboard entirely.
private struct HardwareKeyboardInput: UIViewRepresentable {
    @Binding var text: String
    var filter: (String) -> String

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.inputView = UIView() // Suppress software keyboard
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.autocapitalizationType = .none
        tf.textColor = .clear
        tf.tintColor = .clear
        tf.backgroundColor = .clear
        tf.delegate = context.coordinator
        // Auto-focus to receive hardware keyboard input immediately
        DispatchQueue.main.async { tf.becomeFirstResponder() }
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text {
            tf.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        let parent: HardwareKeyboardInput

        init(parent: HardwareKeyboardInput) {
            self.parent = parent
        }

        func textField(_ tf: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let current = tf.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: swiftRange, with: string)
            let filtered = parent.filter(proposed)
            parent.text = filtered
            tf.text = filtered
            return false
        }
    }
}
