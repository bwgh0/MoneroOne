import SwiftUI
import MoneroKit

struct SendReviewStep: View {
    let recipientAddress: String
    let amountString: String
    let memo: String
    let isSendingAll: Bool
    @Binding var estimatedFee: Decimal?
    /// The transaction this review built and signed, not sent (software
    /// wallets). Send broadcasts this same transaction, so the fee shown is
    /// the fee paid. Nil for a hardware wallet, which keeps the estimate.
    @Binding var preparedSend: PreparedTransaction?
    /// A new value builds the transaction again: the one built here is gone.
    var rebuild = 0
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
        // What leaves the wallet: the amount sent (a sweep's too) and its fee.
        if let prepared = preparedSend {
            return SendReviewFee.total(sent: prepared.amount, fee: prepared.fee)
        }
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
                                CodeText(formatAddress(recipientAddress), color: .label)
                            }

                            Spacer()
                        }
                        .padding()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Recipient: \(recipientAddress)")

                        Divider().padding(.horizontal)

                        // Amount
                        VStack(spacing: 4) {
                            if isSendingAll || upgradedToSendAll {
                                Text("All Funds")
                                    .font(.title.weight(.bold))
                                if let fee = estimatedFee {
                                    let sendAmount = preparedSend.map { SendReviewFee.xmr($0.amount) }
                                        ?? walletManager.displayUnlockedBalance - fee
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
        .task(id: rebuild) {
            await loadFee()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    /// Software wallets: builds and signs the transaction (not sent) and
    /// shows the fee it pays for the inputs it really spends. A hardware
    /// wallet would need the device to build it, so it keeps wallet2's
    /// estimate, which counts one input.
    private func loadFee() async {
        feeError = nil
        estimatedFee = nil
        preparedSend = nil

        guard !walletManager.requiresHardwareSession else {
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
            return
        }

        let memoText = memo.isEmpty ? nil : memo
        let sweep = isSendingAll || upgradedToSendAll
        do {
            let prepared: PreparedTransaction
            do {
                prepared = try await walletManager.prepareSend(to: recipientAddress, amount: sweep ? nil : amount, memo: memoText)
            } catch let error where !sweep && SendReviewFee.shouldSweep(
                after: error, amount: amount, unlockedBalance: walletManager.displayUnlockedBalance
            ) {
                // The amount fits the balance, the amount and its fee do
                // not: the review offers All Funds, as it always has.
                guard !Task.isCancelled else { return }
                prepared = try await walletManager.prepareSend(to: recipientAddress, amount: nil, memo: memoText)
                guard !Task.isCancelled else { return }
                upgradedToSendAll = true
                onUpgradeToSendAll?()
            }
            // Back or a rebuild while it was signing: that review is gone.
            guard !Task.isCancelled else { return }
            preparedSend = prepared
            estimatedFee = SendReviewFee.xmr(prepared.fee)
        } catch {
            guard !Task.isCancelled else { return }
            feeError = error.localizedDescription
        }
    }

    private func formatAddress(_ addr: String) -> String {
        ReceiveAddressLogic.shortAddress(addr)
    }
}

/// The review's fee rules, apart from the view so tests can pin them.
enum SendReviewFee {
    static func xmr(_ piconero: UInt64) -> Decimal {
        Decimal(piconero) / 1_000_000_000_000
    }

    /// What leaves the wallet: the amount sent and its fee. For a sweep
    /// that is the whole unlocked balance.
    static func total(sent: UInt64, fee: UInt64) -> Decimal {
        xmr(sent) + xmr(fee)
    }

    /// wallet2 refused the transfer for lack of unlocked money, with its
    /// real inputs and fee counted.
    static func isNotEnoughMoney(_ error: Error) -> Bool {
        guard let coreError = error as? MoneroCoreError else { return false }
        switch coreError {
        case .insufficientFunds:
            return true
        case .transactionSendFailed(let message):
            return message.lowercased().contains("not enough")
        default:
            return false
        }
    }

    /// Offer All Funds instead: the amount fits the unlocked balance, but
    /// the amount and its fee do not.
    static func shouldSweep(after error: Error, amount: Decimal, unlockedBalance: Decimal) -> Bool {
        isNotEnoughMoney(error) && amount > 0 && amount <= unlockedBalance
    }

    /// A transaction the review built is the payment on screen: it pays
    /// `recipient`, and a transfer (`amount` set) sends exactly that many
    /// XMR. A sweep (`amount` nil) sends what the review showed it would.
    static func matches(preparedAddress: String, preparedAmount: UInt64, preparedFee: UInt64,
                        recipient: String, amount: Decimal?) -> Bool {
        guard preparedAddress == recipient, preparedAmount > 0, preparedFee > 0 else { return false }
        guard let amount else { return true }
        let piconero = MoneroWallet.piconero(amount)
        return piconero > 0 && preparedAmount == UInt64(piconero)
    }
}
