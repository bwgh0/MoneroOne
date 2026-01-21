import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var requestAmount = ""
    @State private var showShareSheet = false
    @State private var selectedAddressIndex: Int = 0 // Default to main address

    private var currentAddress: String {
        if selectedAddressIndex == 0 {
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
        } else {
            // Find the subaddress with this index
            if let subaddr = walletManager.subaddresses.first(where: { $0.index == selectedAddressIndex }) {
                return subaddr.address
            }
            // Subaddress not loaded yet - show loading instead of wrong address
            return "Loading..."
        }
    }

    private var addressLabel: String {
        if selectedAddressIndex == 0 {
            return "Main Address"
        } else {
            return "Subaddress #\(selectedAddressIndex)"
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
                        Text("Request Amount (optional)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("0.0", text: $requestAmount)
                                .font(.system(.body, design: .rounded))
                                .keyboardType(.decimalPad)

                            Text("XMR")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)

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
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
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
                        .buttonStyle(.glass)

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
                        .buttonStyle(.glass)
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
        }
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(12))...\(addr.suffix(8))"
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

struct AddressPickerView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @Binding var selectedIndex: Int
    @State private var isCreating = false

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
                    .disabled(isCreating)
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                // Subaddress Cards (filter out index 0 since it's the main address shown above)
                let actualSubaddresses = walletManager.subaddresses.filter { $0.index > 0 }

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
                    ForEach(actualSubaddresses, id: \.index) { subaddr in
                        AddressCard(
                            label: "Subaddress #\(subaddr.index)",
                            address: subaddr.address,
                            index: subaddr.index,
                            isSelected: selectedIndex == subaddr.index,
                            showWarning: false
                        ) {
                            selectedIndex = subaddr.index
                            dismiss()
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Select Address")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func createNewSubaddress() {
        isCreating = true

        Task {
            let result = walletManager.createSubaddress()

            await MainActor.run {
                isCreating = false

                if result != nil {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                } else {
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

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
}
