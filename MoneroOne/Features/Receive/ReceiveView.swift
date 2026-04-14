import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var requestAmount = ""
    @State private var requestFiatAmount = ""
    @State private var isFiatMode = false
    @State private var showShareSheet = false
    @AppStorage("selectedSubaddressIndex") private var selectedAddressIndex: Int = 0
    @EnvironmentObject var priceService: PriceService

    /// Computes the effective address index, falling back to 0 if selected subaddress doesn't exist
    /// This avoids race conditions by not modifying state during view computation
    private var effectiveAddressIndex: Int {
        if selectedAddressIndex == 0 {
            return 0
        } else if walletManager.subaddresses.contains(where: { $0.index == selectedAddressIndex }) {
            return selectedAddressIndex
        } else {
            // Subaddress doesn't exist (wallet changed or new wallet) - use primary
            return 0
        }
    }

    private var currentAddress: String {
        if effectiveAddressIndex == 0 {
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
        } else {
            if let subaddr = walletManager.subaddresses.first(where: { $0.index == effectiveAddressIndex }) {
                return subaddr.address
            }
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
        }
    }

    private var addressLabel: String {
        if effectiveAddressIndex == 0 {
            return "Main Address"
        } else {
            let subaddresses = walletManager.subaddresses.filter { $0.index > 0 && !$0.address.isEmpty }
            if let subaddr = subaddresses.first(where: { $0.index == effectiveAddressIndex }),
               !subaddr.label.isEmpty {
                return subaddr.label
            }
            if let position = subaddresses.firstIndex(where: { $0.index == effectiveAddressIndex }) {
                return "Subaddress #\(position + 1)"
            }
            return "Subaddress #\(effectiveAddressIndex)"
        }
    }

    private var qrContent: String {
        let addr = currentAddress
        if addr == "Loading..." { return "" }
        if let amount = Decimal(string: requestAmount), amount > 0 {
            return "monero:\(addr)?tx_amount=\(amount)"
        }
        return addr
    }

    private var shareItems: [Any] {
        var items: [Any] = []

        // Generate QR code image
        if let qrImage = QRCodeRenderer.renderToImage(content: qrContent) {
            items.append(qrImage)
        }

        // Create share message
        var message = "Send me Monero (XMR) at this address:\n\n\(currentAddress)"
        if let amount = Decimal(string: requestAmount), amount > 0 {
            message = "Send me \(requestAmount) XMR at this address:\n\n\(currentAddress)"
        }
        items.append(message)

        return items
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Receive XMR")
                        .font(.title2)
                        .fontWeight(.bold)

                    // QR Code
                    if !currentAddress.isEmpty && currentAddress != "Loading..." {
                        QRCodeView(content: qrContent)
                            .frame(width: 280, height: 280)
                            .shadow(color: .black.opacity(0.1), radius: 10)
                            .accessibilityIdentifier("receive.qrCode")
                            .accessibilityLabel("QR code for receiving Monero")
                    } else {
                        Rectangle()
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 280, height: 280)
                            .cornerRadius(20)
                            .overlay {
                                ProgressView()
                            }
                    }

                    // Request Amount (Optional)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request Amount (optional)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Spacer()

                            if priceService.xmrPrice != nil {
                                Button {
                                    toggleReceiveFiatMode()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down")
                                            .font(.caption2.weight(.semibold))
                                        Text(isFiatMode ? "XMR" : priceService.selectedCurrency.uppercased())
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                                .accessibilityLabel("Switch between XMR and \(priceService.selectedCurrency.uppercased()) input")
                            }
                        }

                        HStack {
                            if isFiatMode {
                                Text(priceService.currencySymbol)
                                    .foregroundColor(.secondary)
                                TextField("0.00", text: $requestFiatAmount)
                                    .font(.system(.body, design: .rounded))
                                    .keyboardType(.decimalPad)
                                    .accessibilityLabel("Request amount in \(priceService.selectedCurrency.uppercased())")
                                    .onChange(of: requestFiatAmount) { _ in
                                        syncReceiveXMRFromFiat()
                                    }
                            } else {
                                TextField("0.0", text: $requestAmount)
                                    .font(.system(.body, design: .rounded))
                                    .keyboardType(.decimalPad)
                                    .accessibilityLabel("Request amount in XMR")
                                    .accessibilityHint("Enter an optional amount to embed in the QR code")

                                Text("XMR")
                                    .foregroundColor(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                        // Show converted amount
                        if isFiatMode {
                            if !requestAmount.isEmpty, let amt = Decimal(string: requestAmount), amt > 0 {
                                Text("≈ \(requestAmount) XMR")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                            }
                        } else if let amt = Decimal(string: requestAmount), amt > 0,
                                  let fiat = priceService.formatFiatValue(amt) {
                            Text("≈ \(fiat)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil
                                )
                            }
                        }
                    }

                    // Selected Address Card - Tap to change
                    NavigationLink {
                        AddressPickerView(selectedIndex: $selectedAddressIndex)
                    } label: {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(addressLabel)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)

                                    Text(formatAddress(currentAddress))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                VStack(spacing: 2) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if selectedAddressIndex == 0 {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                    Text("Main address links all transactions. Use subaddresses for privacy.")
                                        .font(.caption2)
                                }
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Privacy warning: Main address links all transactions. Use subaddresses for privacy.")
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("\(addressLabel), \(formatAddress(currentAddress))")
                    .accessibilityHint("Opens address picker to change receiving address")
                    .padding(.horizontal)

                    // Action Buttons
                    HStack(spacing: 16) {
                        // Copy Button
                        Button {
                            copyAddress()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.title3)
                                Text(copied ? "Copied!" : "Copy")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundStyle(copied ? Color.green : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .glassButtonStyle()
                        .accessibilityIdentifier("receive.copyButton")
                        .accessibilityLabel(copied ? "Address copied" : "Copy address")
                        .accessibilityHint("Copies the Monero address to clipboard")

                        // Share Button
                        Button {
                            showShareSheet = true
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                Text("Share")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundStyle(Color.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .glassButtonStyle()
                        .accessibilityLabel("Share address")
                        .accessibilityHint("Opens share sheet with QR code and address")
                    }
                    .padding(.horizontal)
                    .disabled(currentAddress == "Loading...")

                    Spacer(minLength: 40)
                }
                .padding(.top, 24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .onAppear {
                // Reset to main address if selected subaddress doesn't exist
                if selectedAddressIndex > 0 &&
                   !walletManager.subaddresses.contains(where: { $0.index == selectedAddressIndex && !$0.address.isEmpty }) {
                    selectedAddressIndex = 0
                }
            }
        }
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(12))...\(addr.suffix(8))"
    }

    private func toggleReceiveFiatMode() {
        isFiatMode.toggle()
        if isFiatMode {
            // Sync fiat from current XMR
            if let price = priceService.xmrPrice,
               let xmr = Double(requestAmount), xmr > 0 {
                let fiat = xmr * price
                requestFiatAmount = String(format: "%.2f", fiat)
            } else {
                requestFiatAmount = ""
            }
        }
        HapticFeedback.shared.softTick()
    }

    private func syncReceiveXMRFromFiat() {
        guard let price = priceService.xmrPrice, price > 0,
              let fiat = Double(requestFiatAmount), fiat > 0 else {
            requestAmount = ""
            return
        }
        let xmr = fiat / price
        var s = String(format: "%.12f", xmr)
        // Trim trailing zeros
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        requestAmount = s
    }

    private func copyAddress() {
        UIPasteboard.general.string = currentAddress
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Address Picker View

/// Splits a wallet2 label into a leading emoji grapheme (if any) and remaining name.
/// wallet2 stores a single `std::string` per subaddress, so we pack "<emoji> <name>"
/// and parse on edit.
func splitSubaddressLabel(_ raw: String) -> (emoji: String, name: String) {
    guard let first = raw.first else { return ("", "") }
    let isEmoji = first.unicodeScalars.contains {
        $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)
    }
    if isEmoji {
        let name = raw.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), name)
    }
    return ("", raw)
}

/// Packs emoji + name back into wallet2's label string.
func joinSubaddressLabel(emoji: String, name: String) -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    if emoji.isEmpty { return trimmedName }
    if trimmedName.isEmpty { return emoji }
    return "\(emoji) \(trimmedName)"
}

struct AddressPickerView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @Binding var selectedIndex: Int
    @State private var isCreating = false
    @State private var showCreateError = false
    @State private var renameIndex: Int? = nil
    @State private var renameText: String = ""
    @State private var renameEmoji: String = ""

    /// Subaddress creation only needs the wallet pointer (key derivation), not daemon sync
    private var canCreateSubaddress: Bool {
        !walletManager.primaryAddress.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Main Address Card
                AddressCard(
                    label: "Main Address",
                    address: walletManager.primaryAddress,
                    index: 0,
                    isSelected: selectedIndex == 0,
                    showWarning: true
                ) {
                    selectedIndex = 0
                    dismiss()
                }

                // Section Header for Subaddresses
                HStack {
                    Text("Subaddresses")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        createNewSubaddress()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Label("New", systemImage: "plus")
                                .font(.subheadline)
                        }
                    }
                    .disabled(isCreating || !canCreateSubaddress)
                    .accessibilityLabel(isCreating ? "Creating subaddress" : "Create new subaddress")
                    .accessibilityHint("Creates a new subaddress for receiving Monero")
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                // Show all subaddresses except index 0 (main address shown above)
                let actualSubaddresses = walletManager.subaddresses.filter {
                    $0.index > 0 && !$0.address.isEmpty
                }

                if actualSubaddresses.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No subaddresses yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Create subaddresses for better privacy when receiving payments.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(Array(actualSubaddresses.enumerated()), id: \.element.index) { position, subaddr in
                        let displayLabel = subaddr.label.isEmpty ? "Subaddress #\(position + 1)" : subaddr.label
                        AddressCard(
                            label: displayLabel,
                            address: subaddr.address,
                            index: subaddr.index,
                            isSelected: selectedIndex == subaddr.index,
                            showWarning: false,
                            onSelect: {
                                selectedIndex = subaddr.index
                                dismiss()
                            },
                            onRename: {
                                let parts = splitSubaddressLabel(subaddr.label)
                                renameEmoji = parts.emoji
                                renameText = parts.name
                                renameIndex = subaddr.index
                            }
                        )
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Select Address")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Create Address", isPresented: $showCreateError) {
            Button("OK") {}
        } message: {
            Text("Please wait until the wallet finishes syncing and try again.")
        }
        .sheet(isPresented: Binding(
            get: { renameIndex != nil },
            set: { if !$0 { renameIndex = nil } }
        )) {
            RenameSubaddressSheet(
                name: $renameText,
                emoji: $renameEmoji,
                onSave: {
                    if let idx = renameIndex {
                        let packed = joinSubaddressLabel(emoji: renameEmoji, name: renameText)
                        walletManager.setSubaddressLabel(index: idx, label: packed)
                    }
                    renameIndex = nil
                },
                onCancel: { renameIndex = nil }
            )
            .presentationDetents([.medium])
        }
    }

    private func createNewSubaddress() {
        isCreating = true

        Task {
            var result = await walletManager.createSubaddress()

            // Retry once after short delay — wallet2 C++ can fail transiently after node switch
            if result == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                result = await walletManager.createSubaddress()
            }

            await MainActor.run {
                isCreating = false

                if result != nil {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                } else {
                    showCreateError = true
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Address Card (Liquid Glass Style)

struct AddressCard: View {
    let label: String
    let address: String
    let index: Int
    let isSelected: Bool
    let showWarning: Bool
    let onSelect: () -> Void
    var onRename: (() -> Void)? = nil

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            if index == 0 {
                                Text("Primary")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .cornerRadius(4)
                            }
                        }

                        Text(formatAddress(address))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let onRename {
                        Button(action: onRename) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename \(label)")
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }

                if showWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("Links all transactions together")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(isSelected ? Color.green.opacity(0.5) : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(AddressCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(isSelected ? "selected" : "not selected")\(showWarning ? ", warning: links all transactions together" : "")")
        .accessibilityHint("Double tap to select this address")
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(16))...\(addr.suffix(8))"
    }
}

// MARK: - Custom Button Style

struct AddressCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Rename Subaddress Sheet

struct RenameSubaddressSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                EmojiPickerCircle(emoji: $emoji)
                    .padding(.top, 8)

                Text("Tap to pick an emoji")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Label", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .font(.subheadline)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal, 32)

                Text("Labels stay on this device and aren't backed up with your seed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("Rename Subaddress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
