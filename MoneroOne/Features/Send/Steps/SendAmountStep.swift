import SwiftUI

struct SendAmountStep: View {
    @Binding var amountString: String
    @Binding var memo: String
    @Binding var isSendingAll: Bool
    /// The amount the user typed in fiat. The flow keeps it while this step
    /// is gone (back to the recipient), so the amount comes back in fiat.
    @Binding var typedFiat: TypedFiat?
    let recipientAddress: String
    /// The OpenAlias name, when the recipient came from one.
    var recipientDisplayName: String? = nil
    /// A title in place of "Send to …" (Transfer).
    var title: String? = nil
    /// A second line under the title (Transfer: "From Alpha").
    var subtitle: String? = nil
    /// Transfer: To above the amount.
    var header: TransferPartiesCard? = nil
    /// False while Transfer has no wallet under To: Continue waits for one.
    var recipientReady = true
    let unlockedBalance: Decimal
    let priceService: PriceService
    /// Where a filled-in amount came from; the step says so above the amount
    /// until the user first edits it.
    @Binding var amountPrefill: AmountPrefill?
    /// The `monero:` link that filled the flow last. A new one while this
    /// step shows can fill in another amount.
    var paymentRequest: WalletManager.PaymentRequest? = nil
    /// Payment links: no Max, the memo control names the link ("Add note"),
    /// and the title names the link.
    var isLinkMode = false
    /// Link mode: the name the link gets without a note ("Link 9").
    var linkNamePlaceholder = ""
    /// The sheet is wider than a phone's (the open iPhone Duo, iPad): the
    /// flow caps every step at a phone column, and the keys get a 16pt gap
    /// above them.
    var isWideSheet = false
    let onContinue: () -> Void

    enum AmountPrefill {
        case qrCode
        case paymentLink
    }

    /// What changed the amount on this step.
    enum AmountEdit {
        /// A keypad or hardware key: a digit, the decimal point or delete.
        case key
        case paste
        case max
        /// XMR to fiat or back: the same amount in the other unit.
        case unitSwap
    }

    /// A fiat amount as the user typed it, and the XMR amount it made.
    struct TypedFiat: Equatable {
        let fiat: String
        let xmr: String
    }

    @State private var showContent = false
    @State private var showMemo = false
    @State private var softwareKeyboardVisible = false
    @State private var isFiatMode = false
    @State private var fiatString = ""
    /// The fiat the user typed and the XMR worked out from it. A swap to XMR
    /// and back with no edit shows this fiat again, as typed.
    @State private var enteredFiat: TypedFiat?
    /// The fiat a swap from XMR showed, and that XMR. Showing it is not an
    /// edit: the XMR stays exact.
    @State private var swappedFiat: TypedFiat?
    /// A short screen (window under 720pt: iPhone SE, the iPhone Duo). The
    /// amount area is tighter; see `scrollsKeypad` and `squatRowHeight`.
    @State private var isSquat = false
    /// The step's height, the amount area's height and Continue's height:
    /// on the open iPhone Duo the keys get what is left.
    @State private var stepHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var continueHeight: CGFloat = 0

    /// An iPhone 17 Pro key: (402 - 2 x 16 - 2 x 12) / 3 = 115pt wide, 60pt
    /// plus the glass insets = 74pt tall. The open Duo's keys keep this shape.
    private static let keyAspect: CGFloat = 115 / 74
    /// The smallest key row: the 44pt hit target.
    private static let minRowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: isSquat ? 8 : 16) {
                        if let header {
                            header
                                .padding(.top, 4)
                                .padding(.bottom, -8)
                        } else {
                            Spacer(minLength: isSquat ? 4 : 12)
                        }

                        if let amountPrefill {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption2)
                                switch amountPrefill {
                                case .qrCode:
                                    Text("Amount pre-filled from QR code")
                                case .paymentLink:
                                    Text("Amount pre-filled from payment link")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        // Amount display
                        VStack(spacing: 4) {
                            ZStack {
                                // Hidden input for hardware keyboard support (no software keyboard)
                                HardwareKeyboardInput(
                                    text: keyedAmount,
                                    filter: isFiatMode ? filterFiatInput : filterDecimalInput
                                )
                                .id(isFiatMode ? "fiat" : "xmr")
                                .frame(width: 1, height: 1)
                                .opacity(0.01)

                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if isFiatMode {
                                        Text(priceService.currencySymbol)
                                            .font(.title2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Text(fiatString.isEmpty ? "0" : fiatString)
                                            .font(.system(size: 56, weight: .bold, design: .rounded))
                                            .monospacedDigit()
                                            .contentTransition(.numericText())
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.4)
                                    } else {
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
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(isFiatMode
                                    ? "\(fiatString.isEmpty ? "0" : fiatString) \(priceService.selectedCurrency.uppercased())"
                                    : "\(amountString.isEmpty ? "0" : amountString) XMR")
                            }

                            // Secondary amount + swap button
                            Button {
                                toggleFiatMode()
                            } label: {
                                HStack(spacing: 6) {
                                    if isFiatMode {
                                        Text("≈ \(amountString.isEmpty || amountString == "0" ? "0" : amountString) XMR")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .contentTransition(.numericText())
                                    } else if let amountDecimal = Decimal(string: amountString),
                                              amountDecimal > 0,
                                              let fiat = priceService.formatFiatValue(amountDecimal) {
                                        Text("≈ \(fiat)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .contentTransition(.numericText())
                                    } else {
                                        Text("≈ \(priceService.currencySymbol)0")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.brand)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.brand.opacity(0.15))
                                .clipShape(Capsule())
                            }
                            .disabled(priceService.xmrPrice == nil)
                            .accessibilityLabel("Switch between XMR and \(priceService.selectedCurrency.uppercased()) input")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, isSquat ? 4 : 8)

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
                                .foregroundStyle(.brand)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.brand.opacity(0.15))
                                .clipShape(Capsule())
                            }
                            .accessibilityLabel("Paste amount from clipboard")

                            Button("Max") {
                                isFiatMode = false
                                isSendingAll = true
                                amountString = "\(unlockedBalance)"
                                fiatString = ""
                                noteEdit(.max)
                                HapticFeedback.shared.softTick()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.brand)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.brand.opacity(0.15))
                            .clipShape(Capsule())
                            .accessibilityLabel("Send maximum amount")
                            .removedInLinkMode(isLinkMode)
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
                                    Text(memoToggleTitle)
                                        .font(.caption)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .rotationEffect(.degrees(showMemo ? 180 : 0))
                                }
                                .foregroundStyle(.secondary)
                            }

                            if showMemo {
                                TextField(isLinkMode ? linkNamePlaceholder : String(localized: "Add a note"), text: $memo)
                                    .font(.subheadline)
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                    .accessibilityLabel(isLinkMode ? Text("Note") : Text("Add a note"))
                                    .accessibilityHint(isLinkMode ? Text("Only this iPhone keeps the note.") : Text(""))
                                    .onChange(of: memo) { newValue in
                                        // A link's note is a short name.
                                        if isLinkMode, newValue.count > EnvelopeRecord.noteLimit {
                                            memo = String(newValue.prefix(EnvelopeRecord.noteLimit))
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                    }
                    .padding(.horizontal)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)

                    if scrollsKeypad {
                        keypadSection
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)

            if !scrollsKeypad {
                keypadSection
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let subtitle {
                // The title over the subtitle; VoiceOver reads them as one
                // header.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(navigationTitle)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .horizontalBarsOnDuo()
        .onChange(of: amountString) { newValue in
            // Clear send-all when user edits amount
            if isSendingAll {
                let maxStr = "\(unlockedBalance)"
                if newValue != maxStr {
                    isSendingAll = false
                }
            }
        }
        .onChange(of: fiatString) { _ in
            guard isFiatMode,
                  Self.fiatChangeIsEdit(fiat: fiatString, amount: amountString, swapped: swappedFiat) else { return }
            syncXMRFromFiat()
            enteredFiat = TypedFiat(fiat: fiatString, xmr: amountString)
        }
        .onChange(of: paymentRequest) { _, request in
            guard let request else { return }
            // The link's amount is not the fiat the user typed: a swap shows
            // it at the price.
            enteredFiat = nil
            guard isFiatMode else { return }
            if Self.linkKeepsFiat(amount: request.amount) {
                // No amount: the amount starts over, still in fiat, as on a
                // fresh Send.
                fiatString = ""
            } else {
                // The link's amount shows in XMR, as it came, not the old fiat.
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFiatMode = false
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: softwareKeyboardVisible)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
            if !memo.isEmpty { showMemo = true }
            if let fiat = Self.restoredFiat(typedFiat,
                                            amount: amountString,
                                            price: priceService.xmrPrice) {
                fiatString = fiat
                isFiatMode = true
            } else if Self.startsInFiat(fiatMode: priceService.showFiatFirst,
                                        price: priceService.xmrPrice,
                                        amount: amountString) {
                isFiatMode = true
            }
        }
        .detectSquatScreen($isSquat)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            stepHeight = height
        }
        .onDisappear {
            typedFiat = isFiatMode ? TypedFiat(fiat: fiatString, xmr: amountString) : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            softwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            softwareKeyboardVisible = false
        }
    }

    /// The keys and Continue. On a short phone screen they scroll with the
    /// amount, so the amount and its swap button never sit under the keys.
    private var keypadSection: some View {
        VStack(spacing: 12) {
            if !softwareKeyboardVisible {
                NumericKeypad(text: keyedAmount,
                              maxDecimalPlaces: isFiatMode ? 2 : 12,
                              rowHeight: squatRowHeight)
                    .frame(maxWidth: squatRowHeight.map { 3 * $0 * Self.keyAspect + 2 * 8 })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button(action: onContinue) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canContinue ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                continueHeight = height
            }
            .disabled(!canContinue)
            .accessibilityLabel("Continue")
            .accessibilityHint(continueHint)
        }
        .padding(.horizontal)
        .padding(.top, isWideSheet ? 16 : 0)
        .padding(.bottom, 8)
    }

    /// A short phone screen (iPhone SE, the iPhone Duo cover): the keys keep
    /// the iPhone size and scroll with the amount.
    private var scrollsKeypad: Bool { isSquat && !isWideSheet }

    /// On the open iPhone Duo (short and wide): the height of a key row, so
    /// the amount area, the keys and Continue all fit. Nil on other screens
    /// (60pt keys).
    private var squatRowHeight: CGFloat? {
        guard isSquat, isWideSheet, stepHeight > 0, contentHeight > 0 else { return nil }
        // The gap above the keys (16), the keypad VStack's spacing (12) and
        // its bottom padding (8).
        let keypadHeight = stepHeight - contentHeight - 16 - 12 - continueHeight - 8
        let row = (keypadHeight - 3 * 8) / 4
        return min(max(row, Self.minRowHeight), 74).rounded(.down)
    }

    private var navigationTitle: String {
        title ?? (isLinkMode ? String(localized: "Send with a Link") : String(localized: "Send to \(recipientDisplayName ?? formatAddress(recipientAddress))"))
    }

    private var memoToggleTitle: String {
        if isLinkMode {
            return showMemo ? String(localized: "Hide note") : String(localized: "Add note")
        }
        return showMemo ? String(localized: "Hide memo") : String(localized: "Add memo")
    }

    private var continueHint: Text {
        if canContinue { return Text("Proceed to review transaction") }
        if !recipientReady { return Text("Choose a wallet", comment: "Transfer: To before a wallet is chosen") }
        return Text("Enter a valid amount first")
    }

    private var canContinue: Bool {
        guard recipientReady,
              let amount = Decimal(string: amountString),
              amount > 0,
              amount <= unlockedBalance else {
            return false
        }
        return true
    }

    private func pasteAmount() {
        guard let clipboard = UIPasteboard.general.string,
              let amount = Self.pastedAmount(clipboard) else { return }
        amountString = filterDecimalInput(amount)
        noteEdit(.paste)
        HapticFeedback.shared.softTick()
    }

    /// The amount in the shown unit, as the keypad and a hardware keyboard
    /// edit it. An edit there that changes the amount is the user's own.
    private var keyedAmount: Binding<String> {
        let text = isFiatMode ? $fiatString : $amountString
        return Binding(
            get: { text.wrappedValue },
            set: { newValue in
                guard newValue != text.wrappedValue else { return }
                text.wrappedValue = newValue
                noteEdit(.key)
            }
        )
    }

    private func noteEdit(_ edit: AmountEdit) {
        let prefill = Self.prefill(amountPrefill, after: edit)
        guard prefill != amountPrefill else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            amountPrefill = prefill
        }
    }

    /// The note "Amount pre-filled from …" after an edit. It shows while the
    /// amount is still the one that came in: the user's own edit (a key,
    /// delete, Paste, Max) hides it; a unit swap shows the same amount, so it
    /// stays. A new link with an amount shows it again.
    static func prefill(_ prefill: AmountPrefill?, after edit: AmountEdit) -> AmountPrefill? {
        edit == .unitSwap ? prefill : nil
    }

    /// Pasted text as an amount, with "." as the separator. Nil unless the whole text, trimmed, is one
    /// amount: digits with at most one decimal separator (the locale's or ".") and at most 12 decimals.
    /// Digits are never taken out of other text (an address, a link, "1.5 XMR"). Same rule as Android's
    /// `AmountInput.pasted`.
    static func pastedAmount(_ text: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let dotted = decimalSeparator == "." || decimalSeparator.isEmpty
            ? trimmed
            : trimmed.replacingOccurrences(of: decimalSeparator, with: ".")
        let parts = dotted.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2,
              dotted.contains(where: { $0.isASCII && $0.isNumber }),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.count < 2 || parts[1].count <= 12 else { return nil }
        return dotted
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

    /// The unit the amount starts in. Fiat when Fiat Mode is on, like every amount in the app.
    /// XMR when there is no usable price (a fiat amount needs one to convert), and when an amount
    /// is already filled in (a QR code, a `monero:` link, the way back from Review): it stays as it
    /// came, with no rounding through fiat.
    static func startsInFiat(fiatMode: Bool, price: Double?, amount: String) -> Bool {
        guard fiatMode, let price, PriceService.isPlausiblePrice(price) else { return false }
        return amount.isEmpty
    }

    /// The fiat amount to show again when the step comes back (the user went
    /// back to the recipient and continued): the one the user typed, while
    /// the amount is still the XMR it made and a usable price exists. An
    /// amount filled in since (a QR code, a `monero:` link) keeps XMR.
    static func restoredFiat(_ typed: TypedFiat?, amount: String, price: Double?) -> String? {
        guard let typed, !amount.isEmpty, typed.xmr == amount,
              let price, PriceService.isPlausiblePrice(price) else { return nil }
        return typed.fiat
    }

    /// A `monero:` link filled the flow. A link with an amount shows that
    /// amount in XMR, as it came (like any filled-in amount). A link with no
    /// amount keeps the unit and starts the amount over (empty), as a fresh
    /// Send. Either way the fiat the user typed before is dropped, so a
    /// later return does not bring it back.
    static func linkKeepsFiat(amount: String?) -> Bool {
        amount == nil
    }

    private func toggleFiatMode() {
        guard priceService.xmrPrice != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFiatMode.toggle()
        }
        if isFiatMode {
            // The same amount in fiat. The XMR stays as it is, so a swap back
            // gives it back exactly; only a fiat edit works it out again.
            let fiat = Self.fiatAfterSwap(entered: enteredFiat, amount: amountString,
                                          price: priceService.xmrPrice)
            swappedFiat = TypedFiat(fiat: fiat, xmr: amountString)
            fiatString = fiat
        }
        HapticFeedback.shared.softTick()
    }

    /// The fiat a swap from XMR shows: the fiat the user typed, while the
    /// amount is still the XMR it made (a round trip with no edit gives it
    /// back as typed), else the amount at the price.
    static func fiatAfterSwap(entered: TypedFiat?, amount: String, price: Double?) -> String {
        if let typed = restoredFiat(entered, amount: amount, price: price) { return typed }
        guard let price, let xmr = Double(amount), xmr > 0 else { return "" }
        return formatFiatNumber(xmr * price)
    }

    /// A change of the fiat amount that the XMR must follow: anything but the
    /// fiat a swap just showed for this same XMR.
    static func fiatChangeIsEdit(fiat: String, amount: String, swapped: TypedFiat?) -> Bool {
        swapped != TypedFiat(fiat: fiat, xmr: amount)
    }

    private func syncXMRFromFiat() {
        // This division decides how much XMR actually leaves the wallet, so the
        // price it uses has to be sane — `> 0` let through NaN and absurd
        // values that would silently scale the amount up.
        guard let price = priceService.xmrPrice,
              PriceService.isPlausiblePrice(price),
              let fiat = Double(fiatString), fiat > 0 else {
            amountString = ""
            return
        }
        let xmr = fiat / price
        var result = filterDecimalInput(String(format: "%.12f", xmr))
        // Trim trailing zeros for cleaner display
        while result.contains(".") && (result.hasSuffix("0") || result.hasSuffix(".")) {
            result.removeLast()
        }
        amountString = result
    }

    private static func formatFiatNumber(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        // Trim trailing zeros after decimal
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        return s
    }

    private func filterFiatInput(_ input: String) -> String {
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

        // Prevent leading zeros
        if result.count > 1 && result.first == "0" && result.dropFirst().first != "." {
            result = String(result.drop(while: { $0 == "0" }))
            if result.isEmpty || result.first == "." {
                result = "0" + result
            }
        }

        // Limit decimal places to 2 for fiat
        if let dotIndex = result.firstIndex(of: ".") {
            let afterDecimal = result.distance(from: dotIndex, to: result.endIndex) - 1
            if afterDecimal > 2 {
                result = String(result.prefix(result.count - (afterDecimal - 2)))
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
