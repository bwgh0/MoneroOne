import SwiftUI

struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var address = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var showScanner = false
    @State private var showConfirmation = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var estimatedFee: Decimal?
    @State private var sendSuccess = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Offline Banner
                    if !networkMonitor.isConnected {
                        ErrorBanner(
                            message: "No internet connection. Cannot send.",
                            type: .offline
                        )
                    }

                    // Address Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient Address")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Enter XMR address", text: $address)
                                .font(.system(.caption, design: .monospaced))
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .onChange(of: address) { _, _ in
                                    validateAddress()
                                }

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

                        // Address validation indicator
                        if !address.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(isValidAddress ? .green : .red)
                                Text(isValidAddress ? "Valid address" : "Invalid address")
                                    .font(.caption)
                                    .foregroundColor(isValidAddress ? .green : .red)
                            }
                        }
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

                    // Memo (optional)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Memo (optional)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Add a note", text: $memo)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    // Fee estimate
                    if let fee = estimatedFee {
                        HStack {
                            Text("Estimated Fee")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(formatXMR(fee)) XMR")
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    Spacer(minLength: 40)

                    // Send Button
                    Button {
                        validateAndSend()
                    } label: {
                        HStack(spacing: 8) {
                            if isSending {
                                ProgressView()
                                    .tint(isValidInput ? Color.orange : Color.gray)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.callout.weight(.semibold))
                                Text("Send XMR")
                                    .font(.callout.weight(.semibold))
                            }
                        }
                        .foregroundStyle(isValidInput ? Color.orange : Color.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.glass)
                    .disabled(!isValidInput || isSending)
                }
                .padding()
            }
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
                QRScannerView { scannedAddress in
                    address = scannedAddress
                }
            }
            .alert("Confirm Send", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Send", role: .destructive) {
                    sendTransaction()
                }
            } message: {
                let feeText = estimatedFee.map { " + \(formatXMR($0)) fee" } ?? ""
                Text("Send \(amount) XMR\(feeText) to:\n\(formatAddress(address))")
            }
            .alert("Success", isPresented: $sendSuccess) {
                Button("Done") {
                    dismiss()
                }
            } message: {
                Text("Transaction submitted successfully")
            }
        }
    }

    private var isValidAddress: Bool {
        walletManager.isValidAddress(address)
    }

    private var isValidInput: Bool {
        networkMonitor.isConnected &&
        isValidAddress &&
        !amount.isEmpty &&
        (Decimal(string: amount) ?? 0) > 0 &&
        (Decimal(string: amount) ?? 0) <= walletManager.unlockedBalance
    }

    private func validateAddress() {
        errorMessage = nil
        if !address.isEmpty && !isValidAddress {
            errorMessage = "Invalid Monero address"
        }
    }

    private func validateAndSend() {
        errorMessage = nil

        guard isValidAddress else {
            errorMessage = "Invalid Monero address"
            return
        }

        guard let amountDecimal = Decimal(string: amount),
              amountDecimal > 0 else {
            errorMessage = "Invalid amount"
            return
        }

        guard amountDecimal <= walletManager.unlockedBalance else {
            errorMessage = "Insufficient balance"
            return
        }

        // Estimate fee before confirming
        Task {
            do {
                estimatedFee = try await walletManager.estimateFee(to: address, amount: amountDecimal)
                showConfirmation = true
            } catch {
                errorMessage = "Failed to estimate fee: \(error.localizedDescription)"
            }
        }
    }

    private func sendTransaction() {
        isSending = true
        errorMessage = nil

        guard let amountDecimal = Decimal(string: amount) else {
            errorMessage = "Invalid amount"
            isSending = false
            return
        }

        Task {
            do {
                let txHash = try await walletManager.send(
                    to: address,
                    amount: amountDecimal,
                    memo: memo.isEmpty ? nil : memo
                )
                print("Transaction sent: \(txHash)")
                isSending = false
                sendSuccess = true
            } catch {
                errorMessage = "Send failed: \(error.localizedDescription)"
                isSending = false
            }
        }
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 20 else { return addr }
        return "\(addr.prefix(12))...\(addr.suffix(8))"
    }
}

#Preview {
    SendView()
        .environmentObject(WalletManager())
}
