import SwiftUI

struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var address = ""
    @State private var amount = ""
    @State private var showScanner = false
    @State private var showConfirmation = false
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Address Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recipient Address")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Enter XMR address", text: $address)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }

                        Button {
                            if let clipboard = UIPasteboard.general.string {
                                address = clipboard
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }

                // Amount Input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Amount")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Max") {
                            amount = "\(walletManager.unlockedBalance)"
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    }

                    HStack {
                        TextField("0.0", text: $amount)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .keyboardType(.decimalPad)

                        Text("XMR")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Text("Available: \(formatXMR(walletManager.unlockedBalance)) XMR")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Spacer()

                // Send Button
                Button {
                    validateAndSend()
                } label: {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Send XMR")
                    }
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(isValidInput ? Color.orange : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(14)
                .disabled(!isValidInput || isSending)
            }
            .padding()
            .navigationTitle("Send XMR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView(scannedCode: $address)
            }
            .alert("Confirm Send", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Send", role: .destructive) {
                    sendTransaction()
                }
            } message: {
                Text("Send \(amount) XMR to \(address.prefix(20))...?")
            }
        }
    }

    private var isValidInput: Bool {
        !address.isEmpty && address.count >= 95 && // Monero addresses are 95+ chars
        !amount.isEmpty && (Decimal(string: amount) ?? 0) > 0
    }

    private func validateAndSend() {
        errorMessage = nil

        guard address.count >= 95 else {
            errorMessage = "Invalid Monero address"
            return
        }

        guard let amountDecimal = Decimal(string: amount),
              amountDecimal > 0,
              amountDecimal <= walletManager.unlockedBalance else {
            errorMessage = "Invalid amount"
            return
        }

        showConfirmation = true
    }

    private func sendTransaction() {
        isSending = true
        // In real implementation, this would call MoneroKit to send
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isSending = false
            dismiss()
        }
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}

// Simple QR Scanner placeholder
struct QRScannerView: View {
    @Binding var scannedCode: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            Text("QR Scanner")
                .font(.headline)

            Text("Camera access required")
                .foregroundColor(.secondary)

            Button("Done") {
                dismiss()
            }
            .padding()
        }
    }
}

#Preview {
    SendView()
        .environmentObject(WalletManager())
}
