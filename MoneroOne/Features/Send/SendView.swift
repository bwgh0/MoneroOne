import SwiftUI

struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var address = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var showScanner = false
    @State private var showConfirmation = false
    @State private var showProgress = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var estimatedFee: Decimal?
    @State private var transactionHash: String?
    @State private var sendError: String?

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

                    // Wallet Preparing Banner (only in lite mode when not ready)
                    if walletManager.currentSyncMode == .lite && !walletManager.isSendReady {
                        WalletPreparingBanner(progress: walletManager.sendSyncProgress)
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
                                .onChange(of: address) { _ in
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
                                .onChange(of: amount) { newValue in
                                    // Filter to only allow valid decimal input
                                    let filtered = filterDecimalInput(newValue)
                                    if filtered != newValue {
                                        amount = filtered
                                    }
                                }

                            Text("XMR")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                        // Fiat equivalent of entered amount
                        if let amountDecimal = Decimal(string: amount),
                           amountDecimal > 0,
                           let fiatValue = priceService.formatFiatValue(amountDecimal) {
                            Text("≈ \(fiatValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Available: \(formatXMR(walletManager.unlockedBalance)) XMR")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let fiatAvailable = priceService.formatFiatValue(walletManager.unlockedBalance) {
                                Text("(\(fiatAvailable))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
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
                        VStack(spacing: 4) {
                            HStack {
                                Text("Estimated Fee")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(formatXMR(fee)) XMR")
                                    .fontWeight(.medium)
                            }
                            if let fiatFee = priceService.formatFiatValue(fee) {
                                HStack {
                                    Spacer()
                                    Text("≈ \(fiatFee)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
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
                    .glassButtonStyle()
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
            .sheet(isPresented: $showConfirmation) {
                SendConfirmationView(
                    amount: Decimal(string: amount) ?? 0,
                    fee: estimatedFee ?? 0,
                    address: address,
                    onConfirm: {
                        showConfirmation = false
                        showProgress = true
                        sendTransaction()
                    },
                    onCancel: {
                        showConfirmation = false
                    }
                )
            }
            .sheet(isPresented: $showProgress) {
                TransactionProgressView(
                    state: transactionState,
                    onDone: {
                        showProgress = false
                        if transactionHash != nil {
                            dismiss()
                        }
                    },
                    onRetry: sendError != nil ? {
                        sendError = nil
                        sendTransaction()
                    } : nil
                )
            }
        }
    }

    private var isValidAddress: Bool {
        walletManager.isValidAddress(address)
    }

    private var transactionState: TransactionProgressView.TransactionState {
        if let hash = transactionHash {
            return .success(txHash: hash)
        } else if let error = sendError {
            return .error(message: error)
        } else {
            return .sending
        }
    }

    private var isValidInput: Bool {
        networkMonitor.isConnected &&
        isValidAddress &&
        !amount.isEmpty &&
        (Decimal(string: amount) ?? 0) > 0 &&
        (Decimal(string: amount) ?? 0) <= walletManager.unlockedBalance &&
        (walletManager.currentSyncMode == .privacy || walletManager.isSendReady)
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
        transactionHash = nil
        sendError = nil

        guard let amountDecimal = Decimal(string: amount) else {
            sendError = "Invalid amount"
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
                transactionHash = txHash
                await walletManager.refresh()  // Refresh to show the new transaction
                isSending = false
            } catch {
                sendError = "Send failed: \(error.localizedDescription)"
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

    private func filterDecimalInput(_ input: String) -> String {
        // Allow only digits and one decimal point
        var hasDecimal = false
        var result = ""

        for char in input {
            if char.isNumber {
                result.append(char)
            } else if char == "." && !hasDecimal {
                hasDecimal = true
                result.append(char)
            }
        }

        // Limit decimal places to 12 (Monero's precision)
        if let decimalIndex = result.firstIndex(of: ".") {
            let afterDecimal = result.distance(from: decimalIndex, to: result.endIndex) - 1
            if afterDecimal > 12 {
                result = String(result.prefix(result.count - (afterDecimal - 12)))
            }
        }

        return result
    }
}

#Preview {
    SendView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
