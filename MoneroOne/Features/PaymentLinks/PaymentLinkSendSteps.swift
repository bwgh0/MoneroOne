import SwiftUI
import LinkPresentation
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
        // Confirm and the broadcast path both call this. Never replace a saved
        // attempt with the draft's stale, unfunded copy.
        if let saved = store.record(id: record.id, role: .sent) {
            guard saved.link == record.link, saved.address == record.address,
                  saved.amount == record.amount, saved.feeReserve == record.feeReserve,
                  saved.walletId == record.walletId else { throw EnvelopeSecret.Failure.verificationFailed }
            return
        }
        try store.save(record)
    }

    /// Consumes the one funding attempt before software or hardware can send.
    /// `fundingStartedAt` is only the lock: the record stays Created, so it
    /// shows nowhere until its funding transaction is known.
    static func beginFunding(_ record: EnvelopeRecord, walletId: String?, store: EnvelopeStore = .shared, networkType: MoneroKit.NetworkType) throws {
        try save(record, store: store, networkType: networkType)
        guard var saved = store.record(id: record.id, role: .sent),
              saved.walletId == walletId, walletId != nil,
              saved.fundingStartedAt == nil, saved.fundingTxid == nil,
              saved.status == .created else { throw FundingError.alreadyAttempted }
        saved.fundingStartedAt = Date()
        try store.save(saved)
    }

    static func fund(_ record: EnvelopeRecord, walletManager: WalletManager, store: EnvelopeStore = .shared) async throws -> String {
        try beginFunding(record, walletId: walletManager.activeWallet?.id.uuidString, store: store, networkType: walletManager.networkType)
        do {
            let txid = try await walletManager.send(
                to: record.address,
                amount: EnvelopeRuntime.xmr(record.amount + (record.feeReserve ?? 0)),
                memo: memo
            )
            markFunded(id: record.id, txid: txid, store: store)
            return txid
        } catch {
            markNotFunded(id: record.id, nothingSent: WalletManager.sendLeftNothingOnNetwork(error), store: store)
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

    /// The funding failed, or its result is not known. The link is hidden
    /// (Activity, its counts and the balance card leave it out) and keeps
    /// its secret and its used attempt. It shows again, as Waiting, when the
    /// wallet's history or a scan finds its funding. `nothingSent`: the
    /// failure came before anything reached the network, so no scan looks
    /// for it (``EnvelopeStatusRules/needsFundingScan(_:now:)``).
    static func markNotFunded(id: String, nothingSent: Bool = false, store: EnvelopeStore = .shared) {
        guard var record = store.record(id: id, role: .sent), record.fundingTxid == nil else { return }
        record.status = .notFunded
        if nothingSent { record.fundingNotSent = true }
        try? store.save(record)
    }

    /// The Send flow's error when a link's funding may have reached the
    /// network: a broadcast that failed or never reported back.
    nonisolated static var unconfirmedMessage: String {
        String(localized: "The payment could not be confirmed. If it went through, the link appears in Activity.",
               comment: "Send flow error: a payment link's funding may or may not have reached the network")
    }

    /// The sentence that goes with a shared link.
    static func shareText(for record: EnvelopeRecord) -> String? {
        guard let link = record.link else { return nil }
        let amount = XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))
        return String(localized: "I sent you \(amount) XMR. Tap to claim it in Monero One: \(link.url)",
                      comment: "Text shared with a payment link. The first value is the amount, the second the link")
    }

    enum FundingError: LocalizedError {
        case notSynced
        case invalidAmount
        case insufficientFunds
        case alreadyAttempted

        var errorDescription: String? {
            switch self {
            case .notSynced:
                return String(localized: "Wait for your wallet to finish syncing, then try again.")
            case .invalidAmount:
                return String(localized: "Invalid amount")
            case .insufficientFunds:
                return String(localized: "Not enough unlocked funds for the amount, the network fee and the claim fee reserve.")
            case .alreadyAttempted:
                return PaymentLinkFunder.unconfirmedMessage
            }
        }
    }
}

// MARK: - Address step (link mode)

/// Send's recipient when Link is chosen: a token in place of the address
/// field, the same height, so nothing below it moves. ✕ brings the field
/// back with the address typed before.
struct PaymentLinkRecipientToken: View {
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "link")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.brand)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Payment link")
                        .font(.subheadline.weight(.semibold))
                    Text("Anyone with the link can claim it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recipient, payment link. Anyone with the link can claim it")
            .accessibilityIdentifier("send.linkToken")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove payment link")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(minHeight: 54)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Review step (link mode)

struct PaymentLinkReviewStep: View {
    let amountString: String
    @Binding var draft: PaymentLinkDraft?
    /// The link's note, trimmed; empty for none. Shown, never sent.
    var note = ""
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
                        // The note, as Send's review shows a memo.
                        if !note.isEmpty {
                            Divider().padding(.horizontal)
                            HStack {
                                Image(systemName: "note.text")
                                    .foregroundStyle(.secondary)
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Note, \(note)"))
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
                if let record, record.link != nil {
                    PaymentLinkShareButton(record: record) {
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

// MARK: - Sharing a link

/// What the share sheet gets for a payment link. Messages gets the bare
/// URL (a real URL item, so it is tappable) with our own preview ("Claim your Monero", the orange card with the
/// amount), so it shows a card without fetching the page. Every other app
/// gets the usual text with the link. Nothing here loads the URL: its
/// secret is in the fragment.
@MainActor
final class PaymentLinkShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let text: String
    /// Piconero, as the card shows it.
    let amount: UInt64
    /// Drawn on the first request of a share, then reused.
    private var metadata: LPLinkMetadata?

    init?(record: EnvelopeRecord) {
        guard let link = record.link, let url = URL(string: link.url),
              let text = PaymentLinkFunder.shareText(for: record) else { return nil }
        self.url = url
        self.text = text
        self.amount = record.amount
    }

    /// The preview title in Messages and the share sheet.
    static var title: String {
        String(localized: "Claim your Monero", comment: "Title of a shared payment link's preview in Messages and the share sheet")
    }

    static func isMessages(_ activityType: UIActivity.ActivityType?) -> Bool {
        activityType == .message
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        Self.isMessages(activityType) ? url : text
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        linkMetadata()
    }

    /// Built here, never fetched (no LPMetadataProvider): one square card
    /// for the Messages bubble and the share sheet header.
    func linkMetadata() -> LPLinkMetadata {
        if let metadata { return metadata }
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = Self.title
        if let card = PaymentLinkCard.image(amount: amount) {
            metadata.imageProvider = NSItemProvider(object: card)
        }
        self.metadata = metadata
        return metadata
    }
}

/// A control that opens the share sheet for a payment link (one helper for
/// every share point). The sheet comes from UIKit, anchored on the control
/// for the iPad popover. The item is made on the tap.
struct PaymentLinkShareButton<Label: View>: View {
    let record: EnvelopeRecord
    @ViewBuilder let label: () -> Label
    @State private var anchor = ShareAnchor()

    var body: some View {
        Button {
            guard let item = PaymentLinkShareItem(record: record) else { return }
            anchor.present(item)
        } label: {
            label()
        }
        .background(ShareAnchorView(anchor: anchor))
    }
}

/// The UIKit view the share sheet is presented from.
@MainActor
final class ShareAnchor {
    weak var view: UIView?

    func present(_ item: PaymentLinkShareItem) {
        guard let view, var top = view.window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = view.bounds
        top.present(controller, animated: true)
    }
}

private struct ShareAnchorView: UIViewRepresentable {
    let anchor: ShareAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        anchor.view = uiView
    }
}
