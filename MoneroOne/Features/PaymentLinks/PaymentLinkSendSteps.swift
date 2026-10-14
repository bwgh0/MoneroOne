import SwiftUI
import MoneroKit

// MARK: - Draft and funding

/// A payment link built at review and not funded yet. Lives only in memory
/// until the user confirms; then it becomes a saved record.
struct PaymentLinkDraft: Equatable {
    /// A v2 link: it carries neither the amount nor the expiry.
    let link: EnvelopeLink
    let address: String
    /// The amount the recipient gets, piconero.
    let atomicAmount: UInt64
    /// Unix seconds; kept in the sender's record only.
    let expiry: Int64
    /// Claim fee reserve, piconero.
    let feeReserve: UInt64
    /// Fee of the funding transaction, XMR.
    let networkFee: Decimal

    var amount: Decimal { EnvelopeRuntime.xmr(atomicAmount) }
    var reserve: Decimal { EnvelopeRuntime.xmr(feeReserve) }
    /// What the funding transaction sends to the envelope.
    var fundingAmount: Decimal { EnvelopeRuntime.xmr(atomicAmount + feeReserve) }
    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiry)) }
}

@MainActor
enum PaymentLinkFunder {
    static let memo = "Payment link"

    /// The priority the claim fee reserve is sized for. Android sweeps every
    /// claim at wallet2 priority 2 (Priority_Medium), dearer than the iOS
    /// default, and either app can claim a link: reserve for that one. The
    /// kit passes the raw value to wallet2 as its priority.
    static let claimFeePriority: SendPriority = .medium

    /// Builds a new envelope for `amount` XMR and prices it. Generates and
    /// verifies the secret, and fails when the wallet cannot cover the amount,
    /// the network fee and the claim fee reserve.
    static func makeDraft(amount: Decimal, walletManager: WalletManager, now: Date = Date()) async throws -> PaymentLinkDraft {
        let daemonHeight = walletManager.daemonHeight
        guard daemonHeight > 0 else { throw FundingError.notSynced }
        let atomic = EnvelopeRuntime.piconero(amount)
        guard atomic > 0 else { throw FundingError.invalidAmount }

        let networkType = walletManager.networkType
        let secret = try await Task.detached { try EnvelopeSecret.generate(networkType: networkType) }.value

        let restoreHeight = daemonHeight > EnvelopeLink.restoreHeightMargin ? daemonHeight - EnvelopeLink.restoreHeightMargin : 0
        // New links are always v2.
        guard let link = EnvelopeLink(secret: secret.linkSecret, restoreHeight: restoreHeight),
              link.words == secret.words else {
            throw EnvelopeSecret.Failure.generationFailed
        }

        // The reserve is the kit's fee estimate for this funding transaction
        // at the claim priority: the claim sweep (one input, one output)
        // costs no more.
        let reserve = try await walletManager.estimateFee(to: secret.address, amount: amount, priority: claimFeePriority)
        let reserveAtomic = EnvelopeRuntime.piconero(reserve)
        let funding = EnvelopeRuntime.xmr(atomic + reserveAtomic)
        let networkFee = try await walletManager.estimateFee(to: secret.address, amount: funding)
        guard funding + networkFee <= walletManager.displayUnlockedBalance else {
            throw FundingError.insufficientFunds
        }
        return PaymentLinkDraft(
            link: link,
            address: secret.address,
            atomicAmount: atomic,
            expiry: Int64(now.timeIntervalSince1970 + EnvelopeLink.defaultLifetime),
            feeReserve: reserveAtomic,
            networkFee: networkFee
        )
    }

    /// The record saved before the funding broadcast.
    static func record(for draft: PaymentLinkDraft, wallet: WalletInfo?, now: Date = Date()) -> EnvelopeRecord {
        var record = EnvelopeRecord(
            id: draft.link.id,
            role: .sent,
            words: nil,
            address: draft.address,
            restoreHeight: draft.link.restoreHeight,
            amount: draft.atomicAmount,
            expiry: draft.expiry,
            createdAt: now,
            status: .created,
            feeReserve: draft.feeReserve,
            walletName: wallet?.name,
            walletId: wallet?.id.uuidString
        )
        record.setSecret(from: draft.link)
        return record
    }

    /// Saves the record, checks the words once more, then funds through the
    /// normal send path (software wallets). Hardware wallets fund through
    /// `HardwareSessionSheet` and report back with `markFunded`.
    static func save(_ record: EnvelopeRecord, store: EnvelopeStore = .shared, networkType: MoneroKit.NetworkType) throws {
        guard let link = record.link, link.id == record.id else { throw EnvelopeSecret.Failure.verificationFailed }
        try EnvelopeSecret.verify(words: link.words, address: record.address, networkType: networkType)
        try store.save(record)
    }

    static func fund(_ record: EnvelopeRecord, walletManager: WalletManager, store: EnvelopeStore = .shared) async throws -> String {
        try save(record, store: store, networkType: walletManager.networkType)
        do {
            let txid = try await walletManager.send(
                to: record.address,
                amount: EnvelopeRuntime.xmr(record.amount + (record.feeReserve ?? 0)),
                memo: memo
            )
            markFunded(id: record.id, txid: txid, store: store)
            return txid
        } catch {
            markNotFunded(id: record.id, store: store)
            throw error
        }
    }

    static func markFunded(id: String, txid: String, store: EnvelopeStore = .shared) {
        guard var record = store.record(id: id, role: .sent) else { return }
        record.fundingTxid = txid
        record.status = .pending
        record.confirmations = 0
        try? store.save(record)
    }

    static func markNotFunded(id: String, store: EnvelopeStore = .shared) {
        guard var record = store.record(id: id, role: .sent), record.fundingTxid == nil else { return }
        record.status = .notFunded
        try? store.save(record)
    }

    static func shareText(for record: EnvelopeRecord) -> String? {
        guard let link = record.link else { return nil }
        let amount = XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))
        return String(localized: "I sent you \(amount) XMR. Tap to claim it in Monero One: \(link.url)")
    }

    enum FundingError: LocalizedError {
        case notSynced
        case invalidAmount
        case insufficientFunds

        var errorDescription: String? {
            switch self {
            case .notSynced:
                return String(localized: "Wait for your wallet to finish syncing, then try again.")
            case .invalidAmount:
                return String(localized: "Invalid amount")
            case .insufficientFunds:
                return String(localized: "Not enough unlocked funds for the amount, the network fee and the claim fee reserve.")
            }
        }
    }
}

// MARK: - Address step (link mode)

/// The recipient step in link mode: no address, just who can claim.
struct PaymentLinkAddressStep: View {
    let isConnected: Bool
    let onUseAddress: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: String(localized: "No internet connection. Cannot send."),
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.brand.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "link")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.brand)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Anyone with the link")
                                    .font(.headline)
                                Text("You get a link to send in a chat. The first person to open it can claim the money.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .accessibilityElement(children: .combine)
                    }

                    Button(action: onUseAddress) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                            Text("Send to an address")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Send to an address instead")
                }
                .padding()
            }

            Button(action: onContinue) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(isConnected ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!isConnected)
            .padding()
            .accessibilityLabel("Continue")
            .accessibilityHint("Proceed to enter amount")
        }
        .navigationTitle("Send with a Link")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
    }
}

/// The "Send with a link" control under Scan QR and Paste.
struct SendWithLinkButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                Text("Send with a link")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
        .accessibilityLabel("Send with a link")
        .accessibilityHint("Makes a link that anyone you send it to can claim")
        .accessibilityIdentifier("send.withLinkButton")
    }
}

// MARK: - Review step (link mode)

struct PaymentLinkReviewStep: View {
    let amountString: String
    @Binding var draft: PaymentLinkDraft?
    let priceService: PriceService
    let walletManager: WalletManager
    let sendInProgress: Bool
    let onConfirm: () -> Void

    @State private var errorMessage: String?
    @State private var showContent = false

    private var amount: Decimal { Decimal(string: amountString) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 16)

                    VStack(spacing: 0) {
                        recipientRow
                        Divider().padding(.horizontal)
                        amountRow
                        Divider().padding(.horizontal)
                        feeRow(
                            title: String(localized: "Network Fee"),
                            value: draft?.networkFee,
                            note: nil
                        )
                        Divider().padding(.horizontal)
                        feeRow(
                            title: String(localized: "Claim fee reserve"),
                            value: draft?.reserve,
                            note: String(localized: "Covers the recipient's claim fee.")
                        )
                        if let draft {
                            Divider().padding(.horizontal)
                            totalRow(draft.fundingAmount + draft.networkFee)
                            Divider().padding(.horizontal)
                            HStack {
                                Text("Expires")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(draft.expiryDate.formatted(date: .abbreviated, time: .omitted))
                                    .fontWeight(.medium)
                            }
                            .font(.subheadline)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)

                    bearerWarning

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            Button(action: onConfirm) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                        .font(.callout.weight(.semibold))
                    Text("Send")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(draft != nil && !sendInProgress ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(draft == nil || sendInProgress)
            .padding()
            .accessibilityLabel("Send with a link")
            .accessibilityHint(draft != nil ? "Double tap to fund the link with \(XMRFormatter.format(amount)) XMR" : "Preparing the link")
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .task {
            // Same amount as before: keep the envelope already built, so
            // Back and Review again do not make a new secret each time.
            if let draft, draft.atomicAmount == EnvelopeRuntime.piconero(amount) { return }
            draft = nil
            do {
                draft = try await PaymentLinkFunder.makeDraft(amount: amount, walletManager: walletManager)
            } catch {
                errorMessage = EnvelopeSession.message(for: error)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    private var recipientRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Recipient")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Anyone with the link")
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recipient: anyone with the link")
    }

    private var amountRow: some View {
        VStack(spacing: 4) {
            Text("\(XMRFormatter.format(amount)) XMR")
                .font(.title.weight(.bold))
            if let fiat = priceService.formatFiatValue(amount) {
                Text("≈ \(fiat)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private func feeRow(title: String, value: Decimal?, note: String?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.secondary)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let value {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(XMRFormatter.format(value)) XMR")
                        .fontWeight(.medium)
                    if let fiat = priceService.formatFiatValue(value) {
                        Text("≈ \(fiat)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if errorMessage != nil {
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
        .accessibilityLabel(value.map { "\(title): \(XMRFormatter.format($0)) XMR" } ?? "\(title): loading")
    }

    private func totalRow(_ total: Decimal) -> some View {
        HStack {
            Text("Total")
                .fontWeight(.semibold)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(XMRFormatter.format(total)) XMR")
                    .fontWeight(.semibold)
                    .foregroundStyle(.brand)
                if let fiat = priceService.formatFiatValue(total) {
                    Text("≈ \(fiat)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .padding()
        .accessibilityElement(children: .combine)
    }

    private var bearerWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Anyone who has this link can claim the money. Send it to one person in a private chat. You can take the money back until someone claims it.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: Anyone who has this link can claim the money. Send it to one person in a private chat. You can take the money back until someone claims it.")
    }
}

// MARK: - Link ready

struct PaymentLinkReadyStep: View {
    let recordId: String
    let onDone: () -> Void

    @ObservedObject private var store = EnvelopeStore.shared
    @State private var showContent = false

    private var record: EnvelopeRecord? { store.record(id: recordId, role: .sent) }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            SuccessCheckmarkView()
                .frame(height: 160)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Link ready")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.green)
                if let record {
                    Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))) XMR")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Text("Send it to one person in a private chat. Anyone who has this link can claim the money.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .opacity(showContent ? 1 : 0)

            Spacer()

            VStack(spacing: 12) {
                if let record, let text = PaymentLinkFunder.shareText(for: record) {
                    ShareLink(item: text) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Share the link")
                    .accessibilityIdentifier("paymentLink.share")
                }

                Button(action: onDone) {
                    Text("Done")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .accessibilityLabel("Done")
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                showContent = true
            }
        }
    }
}

// MARK: - Helpers

private struct RemovedInLinkMode: ViewModifier {
    let removed: Bool

    func body(content: Content) -> some View {
        if !removed { content }
    }
}

extension View {
    /// Leaves the view out while Send makes a payment link (Max, memo).
    func removedInLinkMode(_ isLinkMode: Bool) -> some View {
        modifier(RemovedInLinkMode(removed: isLinkMode))
    }
}
