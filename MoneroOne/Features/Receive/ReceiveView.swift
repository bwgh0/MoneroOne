import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var requestAmount = ""
    @State private var showShareSheet = false

    private var qrContent: String {
        if let amount = Decimal(string: requestAmount), amount > 0 {
            return "monero:\(walletManager.address)?tx_amount=\(amount)"
        }
        return walletManager.address
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

                    // Address Display
                    VStack(spacing: 8) {
                        Text("Your Address")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(walletManager.address.isEmpty ? "Loading..." : walletManager.address)
                            .font(.system(.caption2, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .textSelection(.enabled)
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
                                    .font(.title2)
                                Text(copied ? "Copied!" : "Copy")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .foregroundColor(copied ? .green : .primary)

                        // Share Button
                        Button {
                            showShareSheet = true
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title2)
                                Text("Share")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .foregroundColor(.primary)
                    }
                    .padding(.horizontal)
                    .disabled(walletManager.address.isEmpty)

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
        UIPasteboard.general.string = walletManager.address
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

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
}
