import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var requestAmount = ""
    @State private var showShareSheet = false
    @State private var showingSubaddress = true

    private var currentAddress: String {
        if showingSubaddress {
            return walletManager.address.isEmpty ? "Loading..." : walletManager.address
        } else {
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Receive XMR")
                        .font(.title2)
                        .fontWeight(.bold)

                    // QR Code
                    if !walletManager.address.isEmpty {
                        QRCodeView(content: qrContent)
                            .frame(width: 220, height: 220)
                            .padding()
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.1), radius: 10)
                    } else {
                        Rectangle()
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 220, height: 220)
                            .cornerRadius(16)
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

                    // Address Type Picker
                    Picker("Address Type", selection: $showingSubaddress) {
                        Text("Subaddress").tag(true)
                        Text("Main Address").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // Address Display
                    VStack(spacing: 8) {
                        Text(showingSubaddress ? "Your Subaddress" : "Your Main Address")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(currentAddress)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .textSelection(.enabled)

                        if !showingSubaddress {
                            Text("Main address links all your transactions. Use subaddresses for better privacy.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal)

                    // Manage Addresses Link
                    NavigationLink {
                        SubaddressListView()
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Manage Addresses")
                        }
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    }
                    .padding(.top, 4)

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
                ShareSheet(items: [qrContent])
            }
        }
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

// MARK: - Subaddress List View

struct SubaddressListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var copiedAddress: String?
    @State private var isCreating = false

    var body: some View {
        List {
            Section("Main Address") {
                AddressRow(
                    label: "Primary",
                    address: walletManager.primaryAddress,
                    index: 0,
                    copiedAddress: $copiedAddress
                )
            }

            Section {
                if walletManager.subaddresses.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No subaddresses yet")
                            .foregroundColor(.secondary)
                        Text("Tap + to create a new subaddress for receiving payments.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(walletManager.subaddresses, id: \.index) { subaddr in
                        AddressRow(
                            label: "Subaddress \(subaddr.index)",
                            address: subaddr.address,
                            index: subaddr.index,
                            copiedAddress: $copiedAddress
                        )
                    }
                }
            } header: {
                Text("Subaddresses")
            } footer: {
                Text("Subaddresses provide privacy by allowing you to receive payments to different addresses that are all linked to your wallet.")
            }
        }
        .navigationTitle("Addresses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createNewSubaddress()
                } label: {
                    if isCreating {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isCreating)
            }
        }
    }

    private func createNewSubaddress() {
        isCreating = true

        Task {
            let result = walletManager.createSubaddress()

            await MainActor.run {
                isCreating = false

                if let newAddr = result {
                    // Provide haptic feedback
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)

                    // Briefly highlight the new address by copying it
                    copiedAddress = newAddr.address
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedAddress == newAddr.address {
                            copiedAddress = nil
                        }
                    }
                } else {
                    // Error feedback
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                }
            }
        }
    }
}

struct AddressRow: View {
    let label: String
    let address: String
    let index: Int
    @Binding var copiedAddress: String?

    private var isCopied: Bool {
        copiedAddress == address
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if index == 0 {
                    Text("Primary")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(4)
                }

                if isCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            Text(formatAddress(address))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copyAddress()
            } label: {
                Label("Copy Full Address", systemImage: "doc.on.doc")
            }

            Button {
                shareAddress()
            } label: {
                Label("Share Address", systemImage: "square.and.arrow.up")
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                copyAddress()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.orange)
        }
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(16))...\(addr.suffix(8))"
    }

    private func copyAddress() {
        UIPasteboard.general.string = address
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        copiedAddress = address
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedAddress == address {
                copiedAddress = nil
            }
        }
    }

    private func shareAddress() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootVC = window.rootViewController else { return }

        let activityVC = UIActivityViewController(activityItems: [address], applicationActivities: nil)
        rootVC.present(activityVC, animated: true)
    }
}

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
}
