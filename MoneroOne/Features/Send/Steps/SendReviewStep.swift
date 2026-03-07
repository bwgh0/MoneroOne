import SwiftUI

struct SendReviewStep: View {
    let recipientAddress: String
    let amountString: String
    let memo: String
    let isSendingAll: Bool
    @Binding var estimatedFee: Decimal?
    let priceService: PriceService
    let walletManager: WalletManager
    let onConfirm: () -> Void

    @State private var feeError: String?
    @State private var showContent = false

    private var amount: Decimal {
        Decimal(string: amountString) ?? 0
    }

    private var total: Decimal? {
        guard let fee = estimatedFee else { return nil }
        return amount + fee
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 16)

                    // Transaction card
                    VStack(spacing: 0) {
                        // Recipient
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "person.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recipient")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatAddress(recipientAddress))
                                    .font(.system(.caption, design: .monospaced))
                            }

                            Spacer()
                        }
                        .padding()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Recipient: \(recipientAddress)")

                        Divider().padding(.horizontal)

                        // Amount
                        VStack(spacing: 4) {
                            Text(isSendingAll ? "All Funds" : "\(XMRFormatter.format(amount)) XMR")
                                .font(.title.weight(.bold))

                            if let fiat = priceService.formatFiatValue(amount) {
                                Text("≈ \(fiat)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)

                        Divider().padding(.horizontal)

                        // Fee
                        HStack {
                            Text("Network Fee")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let fee = estimatedFee {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(XMRFormatter.format(fee)) XMR")
                                        .fontWeight(.medium)
                                    if let fiatFee = priceService.formatFiatValue(fee) {
                                        Text("≈ \(fiatFee)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else if feeError != nil {
                                Text("Error")
                                    .fontWeight(.medium)
                                    .foregroundStyle(.red)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .font(.subheadline)
                        .padding()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(estimatedFee.map { "Network fee: \(XMRFormatter.format($0)) XMR" } ?? "Network fee: loading")

                        // Total
                        if let total = total {
                            Divider().padding(.horizontal)

                            HStack {
                                Text("Total")
                                    .fontWeight(.semibold)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(XMRFormatter.format(total)) XMR")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                    if let fiatTotal = priceService.formatFiatValue(total) {
                                        Text("≈ \(fiatTotal)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .font(.subheadline)
                            .padding()
                        }

                        // Memo
                        if !memo.isEmpty {
                            Divider().padding(.horizontal)

                            HStack {
                                Image(systemName: "note.text")
                                    .foregroundStyle(.secondary)
                                Text(memo)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding()
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)

                    // Fee error
                    if let error = feeError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Send button
            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                            .font(.callout.weight(.semibold))
                        Text("Send")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(estimatedFee != nil ? .orange : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .disabled(estimatedFee == nil)
                .accessibilityLabel("Send transaction")
                .accessibilityHint(estimatedFee != nil ? "Double tap to send \(XMRFormatter.format(amount)) XMR" : "Waiting for fee estimate")
            }
            .padding()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                estimatedFee = try await walletManager.estimateFee(to: recipientAddress, amount: amount)
            } catch {
                feeError = error.localizedDescription
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 20 else { return addr }
        return "\(addr.prefix(12))...\(addr.suffix(8))"
    }
}
