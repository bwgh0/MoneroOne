import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var walletManager: WalletManager

    let amount: Decimal
    let fee: Decimal?
    let address: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var loadedFee: Decimal?
    @State private var feeError: String?

    private var displayFee: Decimal? {
        loadedFee ?? fee
    }

    private var total: Decimal? {
        guard let fee = displayFee else { return nil }
        return amount + fee
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("Confirm Send")
                .font(.title2.weight(.semibold))
                .padding(.top, 8)

            // Details
            VStack(spacing: 12) {
                // Amount
                HStack {
                    Text("Amount")
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(XMRFormatter.format(amount)) XMR")
                            .fontWeight(.medium)
                        if let fiatAmount = priceService.formatFiatValue(amount) {
                            Text("≈ \(fiatAmount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                // Network Fee
                HStack {
                    Text("Network Fee")
                        .foregroundColor(.secondary)
                    Spacer()
                    if let fee = displayFee {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(XMRFormatter.format(fee)) XMR")
                                .fontWeight(.medium)
                            if let fiatFee = priceService.formatFiatValue(fee) {
                                Text("≈ \(fiatFee)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if feeError != nil {
                        Text("Error")
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    } else {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                Divider()

                // Total
                HStack {
                    Text("Total")
                        .fontWeight(.semibold)
                    Spacer()
                    if let total = total {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(XMRFormatter.format(total)) XMR")
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            if let fiatTotal = priceService.formatFiatValue(total) {
                                Text("≈ \(fiatTotal)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("—")
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Recipient
            VStack(alignment: .leading, spacing: 6) {
                Text("Recipient")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(formatAddress(address))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Fee error message
            if let error = feeError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Buttons
            VStack(spacing: 10) {
                Button {
                    onConfirm()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.callout.weight(.semibold))
                        Text("Confirm Send")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundColor(displayFee != nil ? .orange : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .glassButtonStyle()
                .disabled(displayFee == nil)

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.visible)
        .task {
            // Load fee in background if not provided
            if fee == nil {
                do {
                    loadedFee = try await walletManager.estimateFee(to: address, amount: amount)
                } catch {
                    feeError = error.localizedDescription
                }
            }
        }
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 20 else { return addr }
        return "\(addr.prefix(16))...\(addr.suffix(12))"
    }
}

#Preview("With Fee") {
    SendConfirmationView(
        amount: Decimal(string: "0.5")!,
        fee: Decimal(string: "0.000042")!,
        address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H",
        onConfirm: {},
        onCancel: {}
    )
    .environmentObject(PriceService())
    .environmentObject(WalletManager())
}

#Preview("Loading Fee") {
    SendConfirmationView(
        amount: Decimal(string: "0.5")!,
        fee: nil,
        address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H",
        onConfirm: {},
        onCancel: {}
    )
    .environmentObject(PriceService())
    .environmentObject(WalletManager())
}
