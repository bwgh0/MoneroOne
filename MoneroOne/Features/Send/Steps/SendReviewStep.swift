import SwiftUI

struct SendReviewStep: View {
    let recipientAddress: String
    /// Set when the recipient came from an OpenAlias name.
    var aliasSummary: OpenAliasSummary? = nil
    let amountString: String
    let memo: String
    let isSendingAll: Bool
    @Binding var estimatedFee: Decimal?
    let priceService: PriceService
    let walletManager: WalletManager
    let sendInProgress: Bool
    let onConfirm: () -> Void

    @State private var feeError: String?
    @State private var showContent = false
    @State private var upgradedToSendAll = false
    var onUpgradeToSendAll: (() -> Void)?

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
                                    .fill(Color.brand.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "person.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.brand)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recipient")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let aliasSummary {
                                    Text(aliasSummary.name.display)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                CodeText(formatAddress(recipientAddress), color: .label)
                            }

                            Spacer()
                        }
                        .padding(aliasSummary == nil ? .all : [.horizontal, .top])
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(recipientLabel)

                        if let aliasSummary {
                            // Under the text column: the 16 pt padding, the
                            // 40 pt icon disc and the 12 pt spacing of the row.
                            OpenAliasReviewNotes(summary: aliasSummary)
                                .padding(.leading, 68)
                                .padding(.trailing)
                                .padding(.top, 8)
                                .padding(.bottom)
                        }

                        Divider().padding(.horizontal)

                        // Amount
                        VStack(spacing: 4) {
                            if isSendingAll || upgradedToSendAll {
                                Text("All Funds")
                                    .font(.title.weight(.bold))
                                if let fee = estimatedFee {
                                    let sendAmount = walletManager.displayUnlockedBalance - fee
                                    Text("\(XMRFormatter.format(sendAmount)) XMR")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let fiat = priceService.formatFiatValue(sendAmount) {
                                        Text("≈ \(fiat)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("\(XMRFormatter.format(amount)) XMR")
                                    .font(.title.weight(.bold))
                                if let fiat = priceService.formatFiatValue(amount) {
                                    Text("≈ \(fiat)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
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
                        .accessibilityLabel(estimatedFee.map { String(localized: "Network fee: \(XMRFormatter.format($0)) XMR") } ?? String(localized: "Network fee: loading"))

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
                                        .foregroundStyle(.brand)
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
                    .foregroundStyle(estimatedFee != nil && !sendInProgress ? .brand : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .disabled(estimatedFee == nil || sendInProgress)
                .accessibilityLabel("Send transaction")
                .accessibilityHint(estimatedFee != nil ? "Double tap to send \(XMRFormatter.format(amount)) XMR" : "Waiting for fee estimate")
            }
            .padding()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .task {
            do {
                estimatedFee = try await walletManager.estimateFee(to: recipientAddress, amount: amount)

                // If amount + fee exceeds balance, auto-upgrade to send all
                if let fee = estimatedFee, amount + fee > walletManager.displayUnlockedBalance, !isSendingAll {
                    upgradedToSendAll = true
                    onUpgradeToSendAll?()
                }
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

    private var recipientLabel: Text {
        if let aliasSummary {
            return Text("Recipient: \(aliasSummary.name.display), address \(recipientAddress)")
        }
        return Text("Recipient: \(recipientAddress)")
    }

    private func formatAddress(_ addr: String) -> String {
        ReceiveAddressLogic.shortAddress(addr)
    }
}
