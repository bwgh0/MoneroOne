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
    /// Fee of the funding transaction, XMR: the fee of `funding` when the
    /// review built it, else wallet2's estimate (a hardware wallet).
    let networkFee: Decimal
    /// The funding transaction, built and signed at review and not sent
    /// (software wallets). Send broadcasts this same transaction, so the
    /// fee the review showed is the fee it pays. Nil for a hardware
    /// wallet: building it there would need the device.
    var funding: PreparedTransaction? = nil

    var amount: Decimal { EnvelopeRuntime.xmr(atomicAmount) }
    var reserve: Decimal { EnvelopeRuntime.xmr(feeReserve) }
    /// What the funding transaction sends to the envelope.
    var fundingAmount: Decimal { EnvelopeRuntime.xmr(atomicAmount + feeReserve) }
    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiry)) }

    static func == (lhs: PaymentLinkDraft, rhs: PaymentLinkDraft) -> Bool {
        lhs.link == rhs.link && lhs.address == rhs.address && lhs.atomicAmount == rhs.atomicAmount
            && lhs.expiry == rhs.expiry && lhs.feeReserve == rhs.feeReserve && lhs.networkFee == rhs.networkFee
            && lhs.funding === rhs.funding
    }
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
        let draft = PaymentLinkDraft(
            link: link,
            address: secret.address,
            atomicAmount: atomic,
            expiry: Int64(now.timeIntervalSince1970 + EnvelopeLink.defaultLifetime),
            feeReserve: reserveAtomic,
            networkFee: networkFee
        )
        return try await buildFunding(for: draft, walletManager: walletManager)
    }

    /// Builds and signs `draft`'s funding transaction (not sent), and
    /// prices the draft with the fee it pays: wallet2's estimate counts
    /// one input, and a funding pays for each input it spends. The same
    /// envelope; a new transaction. A hardware wallet keeps the estimate:
    /// building there would need the device.
    static func buildFunding(for draft: PaymentLinkDraft, walletManager: WalletManager) async throws -> PaymentLinkDraft {
        guard !walletManager.requiresHardwareSession else { return draft }
        let prepared: PreparedTransaction
        do {
            prepared = try await walletManager.prepareSend(to: draft.address, amount: draft.fundingAmount, memo: memo)
        } catch let error as MoneroCoreError {
            // Not enough once the real inputs are counted.
            if case .insufficientFunds = error { throw FundingError.insufficientFunds }
            if case .transactionSendFailed(let message) = error, message.lowercased().contains("not enough") {
                throw FundingError.insufficientFunds
            }
            throw error
        }
        guard fundingMatches(address: prepared.address, amount: prepared.amount,
                             envelope: draft.address, linkAmount: draft.atomicAmount, feeReserve: draft.feeReserve),
              prepared.fee > 0 else {
            throw FundingError.fundingNotBuilt
        }
        let fee = EnvelopeRuntime.xmr(prepared.fee)
        guard draft.fundingAmount + fee <= walletManager.displayUnlockedBalance else {
            throw FundingError.insufficientFunds
        }
        var built = PaymentLinkDraft(link: draft.link, address: draft.address, atomicAmount: draft.atomicAmount,
                                     expiry: draft.expiry, feeReserve: draft.feeReserve, networkFee: fee)
        built.funding = prepared
        return built
    }

    /// A signed funding pays the link's envelope its amount plus the claim
    /// fee reserve, no more and no less.
    nonisolated static func fundingMatches(address: String, amount: UInt64, envelope: String, linkAmount: UInt64, feeReserve: UInt64) -> Bool {
        !envelope.isEmpty && address == envelope && amount == linkAmount + feeReserve
    }

    /// `draft` can be sent as the review showed it: its funding transaction
    /// is still there to broadcast (a hardware wallet builds at Send).
    static func isReady(_ draft: PaymentLinkDraft, walletManager: WalletManager) async -> Bool {
        if walletManager.requiresHardwareSession { return draft.funding == nil }
        guard let funding = draft.funding else { return false }
        return await walletManager.isPrepared(funding)
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

    /// Saves the signed funding's txids before the broadcast. It is not a
    /// known funding: the link stays hidden until the wallet's history or a
    /// scan shows one of them (``PaymentLinksStatusChecker/fundingUpdates(sent:activeWalletId:walletIds:transactions:)``).
    /// Throws, and nothing is broadcast, when the attempt is not this
    /// link's one funding attempt or the Keychain refuses the save.
    static func saveAttempt(id: String, txids: [String], store: EnvelopeStore = .shared) throws {
        guard !txids.isEmpty, var record = store.record(id: id, role: .sent), record.fundingStartedAt != nil,
              record.fundingTxid == nil, record.attemptTxids == nil else { throw FundingError.alreadyAttempted }
        record.attemptTxids = txids
        try store.save(record)
    }

    /// The step the send runs between signing and broadcast for link `id`.
    static func broadcastStep(id: String, store: EnvelopeStore = .shared) -> MoneroWallet.BeforeBroadcast {
        { prepared in try saveAttempt(id: id, txids: prepared.txids, store: store) }
    }

    /// A hardware funding of link `id` (envelope `address`): the session
    /// saves the txids before the broadcast and marks the link funded right
    /// after it, so its Activity row reads as the link's at once.
    static func hardwareStep(id: String, address: String, store: EnvelopeStore = .shared) -> WalletManager.PendingBroadcastStep {
        WalletManager.PendingBroadcastStep(
            address: address,
            run: broadcastStep(id: id, store: store),
            didBroadcast: { txid in markFunded(id: id, txid: txid, store: store) }
        )
    }

    /// Broadcasts `funding`, the transaction the review built for
    /// `record`, after the funding lock and the save of its txids. When
    /// that transaction is gone (the wallet closed since), it throws
    /// `fundingNotBuilt` before the lock: nothing was sent, and the review
    /// builds it again.
    static func fund(_ record: EnvelopeRecord, funding: PreparedTransaction?, walletManager: WalletManager,
                     store: EnvelopeStore = .shared) async throws -> String {
        guard let funding,
              fundingMatches(address: funding.address, amount: funding.amount,
                             envelope: record.address, linkAmount: record.amount, feeReserve: record.feeReserve ?? 0),
              await walletManager.isPrepared(funding) else { throw FundingError.fundingNotBuilt }
        try beginFunding(record, walletId: walletManager.activeWallet?.id.uuidString, store: store, networkType: walletManager.networkType)
        do {
            let txid = try await walletManager.send(funding, beforeBroadcast: broadcastStep(id: record.id, store: store))
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
        record.fundingFailed = nil
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
        /// The funding transaction the review built is gone (the wallet
        /// closed since) or does not match the link. Nothing was sent.
        case fundingNotBuilt

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
            case .fundingNotBuilt:
                return String(localized: "Could not make the payment link. Nothing was sent.")
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
    /// A new value builds the funding transaction again: the one built
    /// here is gone (the wallet closed since).
    var rebuild = 0
    let onConfirm: () -> Void

    @State private var errorMessage: String?
    /// A failed build offers Retry, except for a lack of funds.
    @State private var errorCanRetry = true
    @State private var showContent = false
    /// The review waits for a running, synced wallet before it builds.
    @State private var isWaitingForSync = true
    /// The wait passed half a second: the status slot above Send shows.
    @State private var isWaitShown = false
    /// Bumped by Retry: the review waits and builds again.
    @State private var retry = 0

    private var amount: Decimal { Decimal(string: amountString) ?? 0 }

    /// An amount in the order Fiat Mode picks, as on the Send Review.
    private func lines(_ xmr: Decimal) -> ReviewAmountLines {
        ReviewAmountLines(xmr: xmr, priceService: priceService)
    }

    /// VoiceOver's label for a fee row, in the order of the screen: in Fiat
    /// Mode the fiat value, then the exact XMR. Otherwise the XMR alone.
    static func valueLabel(title: String, value: Decimal, lines: ReviewAmountLines) -> String {
        "\(title): \(lines.spokenFiatFirst ?? "\(XMRFormatter.format(value)) XMR")"
    }

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
                        // Total and Expires hold their places until the
                        // link is built.
                        Divider().padding(.horizontal)
                        totalRow(draft.map { $0.fundingAmount + $0.networkFee })
                        Divider().padding(.horizontal)
                        HStack {
                            Text("Expires")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let draft {
                                Text(draft.expiryDate.formatted(date: .abbreviated, time: .omitted))
                                    .fontWeight(.medium)
                            } else {
                                Text(Date(timeIntervalSinceNow: EnvelopeLink.defaultLifetime).formatted(date: .abbreviated, time: .omitted))
                                    .fontWeight(.medium)
                                    .redacted(reason: .placeholder)
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.subheadline)
                        .padding()
                        .accessibilityElement(children: .combine)
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
                }
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Send, with the wallet's status or a failed build above it.
            VStack(spacing: 10) {
                SendWaitStatus(
                    walletManager: walletManager,
                    failure: errorMessage,
                    failureCanRetry: errorCanRetry,
                    isWaitShown: isWaitShown,
                    onRetry: {
                        // A failed build builds again; a wait asks the node again.
                        if errorMessage != nil { retry += 1 } else { Task { await walletManager.refresh() } }
                    }
                )

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
                .accessibilityLabel("Send with a link")
                .accessibilityHint(sendHint)
            }
            .padding()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .task(id: [rebuild, retry]) {
            await buildDraft()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    private var sendHint: Text {
        if draft != nil { return Text("Double tap to fund the link with \(XMRFormatter.format(amount)) XMR") }
        return isWaitingForSync ? Text("Waiting for your wallet to sync", comment: "VoiceOver hint on the gray Send button while Review waits for the wallet to sync") : Text("Preparing the link")
    }

    /// Waits for a running, synced wallet (a payment-link check gives it
    /// back at once), then builds the link. The status slot shows only
    /// when the wait takes a moment, and stays until the values are in.
    private func buildDraft() async {
        errorMessage = nil
        // Same amount as before: keep the envelope already built, so Back
        // and Review again do not make a new secret each time. Its funding
        // transaction is built again when it is gone.
        let kept = draft.flatMap { $0.atomicAmount == EnvelopeRuntime.piconero(amount) ? $0 : nil }
        if let kept, await PaymentLinkFunder.isReady(kept, walletManager: walletManager) { return }
        draft = nil
        isWaitingForSync = true
        let showWait = Task { @MainActor in
            try? await Task.sleep(for: SendWaitRules.slotDelay)
            guard !Task.isCancelled else { return }
            withAnimation(SendWaitRules.crossFade) { isWaitShown = true }
        }
        do {
            try await walletManager.awaitReadyToSend()
        } catch {
            // Back or a new build.
            showWait.cancel()
            return
        }
        showWait.cancel()
        isWaitingForSync = false
        do {
            let built: PaymentLinkDraft
            if let kept {
                built = try await PaymentLinkFunder.buildFunding(for: kept, walletManager: walletManager)
            } else {
                built = try await PaymentLinkFunder.makeDraft(amount: amount, walletManager: walletManager)
            }
            guard !Task.isCancelled else { return }
            withAnimation(SendWaitRules.crossFade) {
                draft = built
                isWaitShown = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(SendWaitRules.crossFade) {
                errorCanRetry = SendWaitRules.canRetry(after: error)
                errorMessage = EnvelopeSession.message(for: error)
                isWaitShown = false
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
        let sent = lines(amount)
        return VStack(spacing: 4) {
            Text(verbatim: sent.primary)
                .font(.title.weight(.bold))
            if let secondary = sent.secondary {
                Text(verbatim: secondary)
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
                let valueLines = lines(value)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: valueLines.primary)
                        .fontWeight(.medium)
                    if let secondary = valueLines.secondary {
                        Text(verbatim: secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ReviewValuePlaceholder(lines: lines(ReviewValuePlaceholder.feeSample))
            }
        }
        .font(.subheadline)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { Self.valueLabel(title: title, value: $0, lines: lines($0)) } ?? "\(title): loading")
    }

    private func totalRow(_ total: Decimal?) -> some View {
        HStack {
            Text("Total")
                .fontWeight(.semibold)
            Spacer()
            if let total {
                let totalLines = lines(total)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: totalLines.primary)
                        .fontWeight(.semibold)
                        .foregroundStyle(.brand)
                    if let secondary = totalLines.secondary {
                        Text(verbatim: secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ReviewValuePlaceholder(lines: lines(amount), weight: .semibold)
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

/// The link is funded. The check plays where the spinner turned, then it
/// turns into the note and goes into the envelope (`PaymentLinkSendHero`);
/// Share and Done come in when the seal is on. The step keeps the sending
/// step's layout (its amount and text hold their places, unseen), so the
/// check lands where the spinner turned and "Link ready" where "Sending
/// Transaction..." was.
struct PaymentLinkReadyStep: View {
    let recordId: String
    /// The amount the sending step showed.
    let amountString: String
    let priceService: PriceService
    let onDone: () -> Void

    @ObservedObject private var store = EnvelopeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showContent = false
    /// The seal is on: Share and Done come in.
    @State private var sealed = false

    private var record: EnvelopeRecord? { store.record(id: recordId, role: .sent) }

    /// The link's amount: the note shows it as the sending step did (Fiat
    /// Mode: the fiat amount), the line under "Link ready" the other unit.
    private var figures: SendAmountFigures? {
        let amount = record.map { EnvelopeRuntime.xmr($0.amount) } ?? Decimal(string: amountString)
        return amount.map { SendAmountFigures(amount: $0, priceService: priceService) }
    }

    private var sendingFigures: SendAmountFigures? {
        Decimal(string: amountString).map { SendAmountFigures(amount: $0, priceService: priceService) }
    }

    var body: some View {
        let figures = self.figures
        VStack(spacing: 32) {
            Spacer()

            if let sendingFigures {
                SendAmountHeader(figures: sendingFigures)
                    .hidden()
            }

            // The spinner's slot: the hero rises from it over the amount's place.
            Color.clear
                .frame(height: 160)
                .overlay(alignment: .bottom) {
                    PaymentLinkSendHero(amount: EnvelopeCardAmount(text: figures?.hero ?? "", showsUnit: figures?.showsUnit ?? true)) {
                        sealed = true
                    }
                }

            ZStack(alignment: .top) {
                SendingStatusText()
                    .hidden()
                PaymentLinkReadyText(figures: figures)
                    .opacity(showContent ? 1 : 0)
            }

            Spacer()

            PaymentLinkReadyActions(record: record, isShown: sealed, onDone: onDone)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .padding()
        .onAppear {
            // Today's timing; Reduce Motion: with the envelope's cross-fade.
            withAnimation(reduceMotion ? .easeInOut(duration: 0.35) : .easeOut(duration: 0.4).delay(0.3)) {
                showContent = true
            }
        }
    }
}

/// "Link ready", the other unit, and what to do with the link.
struct PaymentLinkReadyText: View {
    let figures: SendAmountFigures?

    var body: some View {
        VStack(spacing: 12) {
            Text("Link ready")
                .font(.title.weight(.bold))
                .foregroundStyle(.green)
            if let figures, let line = figures.secondary {
                Text(verbatim: line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    // The note is hidden from VoiceOver: its amount comes here.
                    .accessibilityLabel(Text(verbatim: "\(figures.hero)\(figures.showsUnit ? " XMR" : ""), \(line)"))
            }
            Text("Send it to one person in a private chat. Anyone who has this link can claim the money.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

/// Share and Done. With no record, the same buttons hold their place (the
/// sending step keeps it).
struct PaymentLinkReadyActions: View {
    let record: EnvelopeRecord?
    /// Share, then Done, arrive (0.1 s apart) when this turns true.
    var isShown = true
    var onDone: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let record {
                    if record.link != nil {
                        PaymentLinkShareButton(record: record) { shareLabel }
                            .glassButtonStyle()
                            .accessibilityLabel("Share the link")
                            .accessibilityIdentifier("paymentLink.share")
                    }
                } else {
                    Button {} label: { shareLabel }
                        .glassButtonStyle()
                }
            }
            .modifier(ReadyArrive(isShown: isShown, delay: 0.1, reduceMotion: reduceMotion))

            Button(action: onDone) {
                Text("Done")
                    .font(.callout.weight(.medium))
                    // Plain gray: `.secondary` takes on the button's orange tint.
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Done")
            .modifier(ReadyArrive(isShown: isShown, delay: 0.2, reduceMotion: reduceMotion))
        }
    }

    private var shareLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up")
            Text("Share")
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.brand)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// `arrive`: fade in and rise 20 pt (easeOut 0.4 s after `delay`).
/// Reduce Motion: a cross-fade (0.35 s), no rise.
private struct ReadyArrive: ViewModifier {
    let isShown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 20)
            .animation(reduceMotion ? .easeInOut(duration: 0.35) : .easeOut(duration: 0.4).delay(delay), value: isShown)
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
