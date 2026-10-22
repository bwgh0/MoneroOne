import SwiftUI
import MoneroKit

struct SendFlowView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// Transfer (the wallet switcher): the root lists your other wallets in
    /// place of the address step, and a pick goes on to the amount.
    private let isTransfer: Bool
    /// Transfer: the wallet picked under To. Its saved primary address is
    /// `recipientAddress`.
    @State private var transferTarget: WalletInfo?
    @ObservedObject private var contactStore = ContactStore.shared
    @State private var showContacts = false

    /// Transfer: Done on Sent also closes the wallet switcher.
    private let onTransferDone: (() -> Void)?

    init(isTransfer: Bool = false, onTransferDone: (() -> Void)? = nil) {
        self.isTransfer = isTransfer
        self.onTransferDone = onTransferDone
    }

    @State private var phase: SendFlowPhase = .address

    // Send data
    /// The only address that reaches the fee estimate and the send.
    @State private var recipientAddress = ""
    /// The text of the recipient field: an address or an OpenAlias name.
    @State private var recipientInput = ""
    /// Set on Continue with a resolved OpenAlias name, nil for an address.
    @State private var aliasSummary: OpenAliasSummary?
    @StateObject private var aliasLookup = OpenAliasLookupModel()
    @State private var amountString = ""
    @State private var memo = ""
    @State private var isSendingAll = false
    @State private var estimatedFee: Decimal?
    /// The transaction the review built and signed, not sent (software
    /// wallets). Send broadcasts it, so the fee shown is the fee paid.
    @State private var preparedSend: PreparedTransaction?
    /// What the broadcast transaction paid the recipient. Sent shows it
    /// after Max, where the field held the balance.
    @State private var sentAmount: Decimal?
    /// Bumped when that transaction is gone at Send: the review builds it
    /// again and shows its fee; nothing is sent.
    @State private var reviewRebuild = 0
    @State private var transactionHash: String?

    // UI state
    @State private var showScanner = false
    @State private var sendInProgress = false
    @State private var amountPrefill: SendAmountStep.AmountPrefill?
    /// The `monero:` link this flow shows, released when the user confirms
    /// or closes Send.
    @State private var shownPaymentRequest: WalletManager.PaymentRequest?

    @StateObject private var biometricAuth = BiometricAuthManager()
    /// Re-authenticate before broadcasting. On by default: every unlocked
    /// session is otherwise a standing authorization to drain the wallet.
    @AppStorage("requireAuthForSend") private var requireAuthForSend = true

    /// A pure view-only wallet (no spend key anywhere) can never sign.
    /// Hardware wallets *can* sign, just through a device session, so
    /// they're allowed through the SendFlow — the actual signing routes
    /// through `HardwareSessionSheet` at the end. wallet2 still rejects
    /// `createTransaction` for genuinely view-only wallets as a safety
    /// net; this flag blocks the flow up front so the user sees the
    /// reason instead of a mid-flow error.
    private var canSign: Bool {
        walletManager.canSend
    }

    /// Hardware-wallet send sheet presented when the user confirms at
    /// the review step. Only set for hardware-backed active wallets;
    /// software wallets take the direct `walletManager.send` path.
    @State private var hardwareSheetIntent: HardwareSessionSheet.Intent? = nil

    // Payment links (Features/PaymentLinks): the Link recipient funds a new
    // envelope instead of paying an address.
    @State private var isLinkMode = false
    @State private var linkDraft: PaymentLinkDraft?
    /// Bumped when the review's funding transaction is gone at Send: the
    /// review builds it again, and its fee shows before anything is saved.
    @State private var linkFundingRebuild = 0
    /// The funding transaction of the draft the user confirmed: Send
    /// broadcasts this one.
    @State private var linkFunding: PreparedTransaction?
    @State private var linkRecordId: String?
    /// The link's note: a name that stays on this iPhone, never in the link
    /// or the funding transaction's memo.
    @State private var linkNote = ""

    /// Link as the recipient. It clears Send All: a link holds the amount
    /// typed in.
    private var linkModeBinding: Binding<Bool> {
        Binding(
            get: { isLinkMode },
            set: { isOn in
                if isOn { isSendingAll = false }
                isLinkMode = isOn
            }
        )
    }

    var body: some View {
        // Amount, Review and the status step are pushes, so the system back
        // button and the edge swipe go back one step, as in Receive's
        // Select Address.
        NavigationStack(path: stepPath) {
            ZStack {
                if canSign {
                    if isTransfer {
                        TransferWalletList(onPick: pickTransferTarget)
                    } else {
                        phaseContent(.address)
                    }
                } else {
                    viewOnlyBlockedView
                }
            }
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if canSign {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: SendFlowStep.self) { step in
                switch step {
                case .amount:
                    phaseContent(.amount)
                case .review:
                    phaseContent(.review)
                case .status:
                    // Sending, success and failure have no way back: no back
                    // button, and so no edge swipe.
                    phaseContent(statusPhase)
                        .navigationBarBackButtonHidden()
                        .horizontalBarsOnDuo()
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scannedAddress, scannedAmount in
                    // A scanned address replaces a chosen link.
                    isLinkMode = false
                    recipientInput = scannedAddress
                    if case .address = OpenAlias.classify(scannedAddress) {
                        recipientAddress = scannedAddress
                    }
                    // A name starts its lookup at once, on this step.
                    aliasLookup.submit(scannedAddress)
                    if let amount = scannedAmount {
                        amountString = amount
                        amountPrefill = .qrCode
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase.isSendingState)
        .onAppear {
            walletManager.isSendFlowPresented = true
            aliasLookup.network = walletManager.networkType
            handlePrefill()
        }
        .onChange(of: recipientInput) { _, newValue in
            aliasLookup.textChanged(newValue)
        }
        .onChange(of: walletManager.pendingPaymentRequest) { _, newRequest in
            // A link tapped while Send is open replaces what is on screen.
            // Once the user has confirmed, it must not touch this flow, and
            // holding it would fill the next Send the user opens on purpose,
            // so it is refused with a message instead.
            guard let request = newRequest, request != shownPaymentRequest else { return }
            // Transfer pays one of your wallets: a link never changes it.
            guard !isTransfer, phase.acceptsPaymentRequest else {
                walletManager.refusePaymentRequest(
                    request,
                    message: String(localized: "Send is still showing another payment. Close it, then open the link again.")
                )
                return
            }
            apply(request, animated: true)
        }
        .onChange(of: phase) { _, newPhase in
            // Leaving the review (Back, a swipe, a link): its transaction
            // belongs to what it showed.
            if newPhase == .address || newPhase == .amount {
                discardPreparedSend()
            }
        }
        .onChange(of: phase) { _, newPhase in
            // A send that went out (every path ends in `.success`): the
            // wallet home asks for Apple's review prompt once it shows.
            ReviewPromptGate().sendPhaseChanged(to: newPhase)
        }
        .onChange(of: phase) { _, newPhase in
            aliasLookup.recordPinIfSent(phase: newPhase, summary: aliasSummary, sentAddress: recipientAddress)
            // Confirmed: this link must never open Send again.
            guard newPhase.isSendingState, let shownPaymentRequest else { return }
            walletManager.releasePaymentRequest(shownPaymentRequest, confirmed: true)
        }
        .onChange(of: recipientInput) { old, text in
            // A claim link pasted or scanned here opens the claim sheet. It is
            // never an address.
            guard EnvelopeLink.looksLikeClaimLink(text) else { return }
            // Typed, the link is incomplete until its last key: wait for a
            // whole link. A paste or scan lands in one change and gets an
            // answer even when it is broken.
            let pasted = text.count - old.count > 16
            if !pasted, (try? EnvelopeLink.parse(text)) == nil { return }
            aliasLookup.cancel()
            recipientInput = ""
            recipientAddress = ""
            PaymentLinksCoordinator.shared.handle(text: text, networkType: walletManager.networkType, activeAddress: walletManager.primaryAddress)
            dismiss()
        }
        .onDisappear {
            walletManager.isSendFlowPresented = false
            aliasLookup.cancel()
            guard let shownPaymentRequest else { return }
            walletManager.releasePaymentRequest(shownPaymentRequest, confirmed: false)
        }
        .sheet(item: $hardwareSheetIntent, onDismiss: handleHardwareSheetDismiss) { intent in
            HardwareSessionSheet(
                intent: intent,
                trezorManager: walletManager.trezorManager
            )
            .environmentObject(walletManager)
        }
        // A refused link shows its alert here while Send is open: from the
        // app root it would close this sheet, even mid-send. It waits while
        // the scanner or the hardware sheet is up.
        .alert(
            "Can't Open Payment Link",
            isPresented: Binding(
                get: { walletManager.paymentLinkError != nil && !showScanner && hardwareSheetIntent == nil },
                set: { if !$0 { walletManager.paymentLinkError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(walletManager.paymentLinkError ?? "")
        }
    }

    /// Called when the hardware-session sheet dismisses. Use the
    /// outcome flag the WalletManager set during the run to decide
    /// what to do with the parent SendFlow:
    ///   - `sentTransaction`: dismiss the SendFlow and bounce the
    ///     user back to the wallet view with refreshed balances.
    ///   - `syncedOnly` / nil: shouldn't really happen from the
    ///     send flow, but treat as "leave open".
    ///   - `failed`: keep SendFlow visible so the user can adjust
    ///     amount/address and retry without restarting from
    ///     address-entry. Snap back to `.review` so the inputs are
    ///     editable instead of stuck on the dead `.sending` step.
    private func handleHardwareSheetDismiss() {
        let outcome = walletManager.lastHardwareSessionOutcome
        walletManager.pendingBroadcastStep = nil
        // Before the refresh, so the new row shows with its name.
        if case .sentTransaction(let txId) = outcome, !isLinkMode {
            recordWalletSend(txid: txId)
        }
        Task {
            await walletManager.refresh()
            await MainActor.run {
                switch outcome {
                case .sentTransaction(let txId):
                    if isLinkMode, let linkRecordId {
                        PaymentLinkFunder.markFunded(id: linkRecordId, txid: txId)
                    }
                    // Show the same confetti / success animation
                    // software-wallet sends get. Phase was set to
                    // `.sending` when the user tapped Confirm, so
                    // SendStatusStep is already on screen behind
                    // the just-dismissed HW sheet — let the sending
                    // animation breathe for a beat so the user
                    // perceives the broadcast step before we slam
                    // straight to confetti, then flip to .success.
                    transactionHash = txId
                    sendInProgress = false
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        await MainActor.run {
                            HapticFeedback.shared.transactionSuccess()
                            SoundFeedback.shared.playSendComplete()
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                phase = .success(txHash: txId)
                            }
                        }
                    }
                case .failed(let message, let mayHaveSent):
                    sendInProgress = false
                    // A link used its one funding attempt: no way back to
                    // Confirm. It shows the error as a normal send does and
                    // stays hidden until a funding turns up.
                    if isLinkMode, let linkRecordId {
                        PaymentLinkFunder.markNotFunded(id: linkRecordId, nothingSent: !mayHaveSent)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            phase = .error(message: message)
                        }
                        return
                    }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        phase = .review
                    }
                case .syncedOnly, .none:
                    sendInProgress = false
                    // A link: the sheet closed without a result (cancelled,
                    // dismissed, or a failure after the broadcast), so the
                    // funding may have gone out. Its one attempt is used.
                    if isLinkMode, let linkRecordId {
                        PaymentLinkFunder.markNotFunded(id: linkRecordId)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            phase = .error(message: PaymentLinkFunder.unconfirmedMessage)
                        }
                        return
                    }
                    // No send ran — the user cancelled or dismissed the sheet
                    // mid-session. Phase is still `.sending`, which has no
                    // toolbar button, no action area, and disables interactive
                    // dismissal, so leaving it there strands the user with no
                    // way out but force-quitting. Return to `.review` so the
                    // inputs are editable and Send is tappable again.
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        phase = .review
                    }
                }
            }
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private func phaseContent(_ shown: SendFlowPhase) -> some View {
        switch shown {
        case .address:
            SendAddressStep(
                recipientInput: $recipientInput,
                showScanner: $showScanner,
                isLinkMode: linkModeBinding,
                isConnected: networkMonitor.isConnected,
                isValidAddress: walletManager.isValidAddress(recipientInput),
                matchedWallet: matchedWallet,
                matchedContact: matchedContact,
                contactMatches: contactMatches,
                onShowContacts: { showContacts = true },
                onPickContact: pickContact,
                lookup: aliasLookup,
                onContinue: { summary in
                    HapticFeedback.shared.buttonPress()
                    if let summary {
                        recipientAddress = summary.address
                    } else {
                        recipientAddress = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    aliasSummary = summary
                    goForward(to: .amount)
                }
            )
            .sheet(isPresented: $showContacts) {
                ContactsSheet(selectedId: matchedContact?.id, onPick: pickContact)
                    .environmentObject(walletManager)
            }

        case .amount:
            SendAmountStep(
                amountString: $amountString,
                memo: isLinkMode ? $linkNote : $memo,
                isSendingAll: $isSendingAll,
                recipientAddress: recipientAddress,
                recipientDisplayName: walletRecipient?.name ?? matchedContact?.name ?? aliasSummary?.name.display,
                unlockedBalance: walletManager.displayUnlockedBalance,
                priceService: priceService,
                amountPrefill: amountPrefill,
                isLinkMode: isLinkMode,
                linkNamePlaceholder: EnvelopeRecord.linkName(EnvelopeStore.shared.nextNumber),
                onContinue: {
                    HapticFeedback.shared.buttonPress()
                    goForward(to: .review)
                }
            )

        case .review where isLinkMode:
            PaymentLinkReviewStep(
                amountString: amountString,
                draft: $linkDraft,
                note: linkNote.trimmingCharacters(in: .whitespacesAndNewlines),
                priceService: priceService,
                walletManager: walletManager,
                sendInProgress: sendInProgress,
                rebuild: linkFundingRebuild,
                onConfirm: confirmLink
            )

        case .success where isLinkMode && linkRecordId != nil:
            PaymentLinkReadyStep(recordId: linkRecordId ?? "", onDone: { dismiss() })

        case .review:
            SendReviewStep(
                recipientAddress: recipientAddress,
                aliasSummary: aliasSummary,
                transfer: transferParties,
                contact: matchedContact,
                amountString: amountString,
                memo: memo,
                isSendingAll: isSendingAll,
                estimatedFee: $estimatedFee,
                preparedSend: $preparedSend,
                rebuild: reviewRebuild,
                priceService: priceService,
                walletManager: walletManager,
                sendInProgress: sendInProgress,
                onConfirm: {
                    guard !sendInProgress else { return }
                    sendInProgress = true
                    Task {
                        // A software wallet broadcasts the transaction this
                        // review built. Gone (the wallet closed since) or not
                        // this payment: the review builds it again and shows
                        // its fee; nothing is sent.
                        if !walletManager.requiresHardwareSession, !(await preparedSendIsReady()) {
                            sendInProgress = false
                            discardPreparedSend()
                            reviewRebuild += 1
                            return
                        }
                        // Hardware wallets are already re-authenticated
                        // out-of-band — the user has to confirm on the device
                        // before it will sign — so only gate software wallets.
                        if requireAuthForSend, !walletManager.requiresHardwareSession {
                            let approved = await biometricAuth.authenticateForTransaction(
                                reason: String(localized: "Confirm sending \(amountString) XMR")
                            )
                            guard approved else {
                                sendInProgress = false
                                return
                            }
                        }
                        HapticFeedback.shared.sendInitiated()
                        goForward(to: .sending)
                        sendTransaction()
                    }
                },
                onUpgradeToSendAll: {
                    isSendingAll = true
                }
            )

        case .sending, .success, .error:
            SendStatusStep(
                phase: shown,
                amountString: SentAmount.text(typed: amountString, isSendingAll: isSendingAll, sent: sentAmount),
                priceService: priceService,
                onDone: {
                    if isTransfer { onTransferDone?() }
                    dismiss()
                },
                onRetry: {
                    guard !isLinkMode, !sendInProgress else { return }
                    // A software send broadcasts only a transaction a review
                    // built and showed. Retry builds a new one there, with
                    // its own fee.
                    guard walletManager.requiresHardwareSession else {
                        HapticFeedback.shared.buttonPress()
                        discardPreparedSend()
                        goBack(to: .review)
                        return
                    }
                    sendInProgress = true
                    Task {
                        if requireAuthForSend, !walletManager.requiresHardwareSession {
                            let approved = await biometricAuth.authenticateForTransaction(
                                reason: String(localized: "Confirm sending \(amountString) XMR")
                            )
                            guard approved else {
                                sendInProgress = false
                                return
                            }
                        }
                        goForward(to: .sending)
                        sendTransaction()
                    }
                },
                onClose: { dismiss() },
                canRetry: !isLinkMode,
                successNote: transferTarget.map {
                    String(localized: "It shows in \($0.name) when you next open that wallet.", comment: "Transfer sent: the wallet that receives it")
                }
            )
        }
    }

    /// Confirm on the link review: authenticate, save the envelope, fund it.
    private func confirmLink() {
        guard !sendInProgress, let draft = linkDraft else { return }
        sendInProgress = true
        Task {
            if requireAuthForSend, !walletManager.requiresHardwareSession {
                // The link amount, its claim fee reserve and the network fee.
                let total = XMRFormatter.format(draft.fundingAmount + draft.networkFee)
                let approved = await biometricAuth.authenticateForTransaction(
                    reason: String(localized: "Confirm sending \(total) XMR")
                )
                guard approved else {
                    sendInProgress = false
                    return
                }
            }
            // Send broadcasts the funding transaction the review built. Gone
            // (the wallet closed since): the review builds it again and
            // shows its fee; nothing is saved.
            guard await PaymentLinkFunder.isReady(draft, walletManager: walletManager) else {
                sendInProgress = false
                linkFundingRebuild += 1
                return
            }
            // Saved (status created) before anything is broadcast, so the
            // words exist on this iPhone whatever happens next.
            var record = PaymentLinkFunder.record(for: draft, wallet: walletManager.activeWallet)
            let note = linkNote.trimmingCharacters(in: .whitespacesAndNewlines)
            record.note = note.isEmpty ? nil : note
            do {
                try PaymentLinkFunder.save(record, networkType: walletManager.networkType)
            } catch {
                sendInProgress = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    phase = .error(message: EnvelopeSession.message(for: error))
                }
                HapticFeedback.shared.error()
                return
            }
            linkRecordId = record.id
            linkFunding = draft.funding
            HapticFeedback.shared.sendInitiated()
            goForward(to: .sending)
            sendTransaction()
        }
    }

    // MARK: - View-only block

    /// Shown in place of the send flow when the active wallet cannot sign
    /// locally — today that's view-only, later that's also a hardware wallet
    /// without the device present. The close button exits the sheet.
    private var viewOnlyBlockedView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "eye.slash.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.brand)

            Text("View-Only Wallet")
                .font(.title2.weight(.semibold))

            Text("This wallet was restored from a private view key, so it can't sign transactions on this device. To spend, open the wallet that owns the spend key.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Navigation

    /// The stack follows `phase`. A pop by the back button or the edge swipe
    /// writes the shorter path back as the phase one step earlier. A wallet
    /// that cannot sign shows only the root.
    private var stepPath: Binding<[SendFlowStep]> {
        Binding(
            get: { canSign ? phase.stackPath : [] },
            set: { phase = phase.popped(to: $0) }
        )
    }

    /// What the status step shows. While it pops back to Review (a hardware
    /// send that did not run), it keeps showing Sending, as before the pop.
    private var statusPhase: SendFlowPhase {
        phase.stackPath.last == .status ? phase : .sending
    }

    private func goForward(to newPhase: SendFlowPhase) {
        move(to: newPhase, animation: .spring(response: 0.3, dampingFraction: 0.85))
    }

    private func goBack(to newPhase: SendFlowPhase) {
        move(to: newPhase, animation: .spring(response: 0.5, dampingFraction: 0.8))
    }

    /// A push or a pop brings the system's own motion, so only a change inside
    /// the status step (Retry) uses the spring.
    private func move(to newPhase: SendFlowPhase, animation: Animation) {
        if newPhase.stackPath == phase.stackPath {
            withAnimation(animation) { phase = newPhase }
        } else {
            phase = newPhase
        }
    }

    /// Opens the flow on a later step with no push animation (a prefilled
    /// address, amount or payment link).
    private func jump(to newPhase: SendFlowPhase) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { phase = newPhase }
    }

    // MARK: - Transfer

    /// A To row on Transfer: its wallet's saved address, checked as Send
    /// checks an address, then the amount.
    private func pickTransferTarget(_ wallet: WalletInfo, address: String) {
        guard walletManager.isValidAddress(address) else { return }
        HapticFeedback.shared.buttonPress()
        isLinkMode = false
        aliasSummary = nil
        transferTarget = wallet
        recipientAddress = address
        goForward(to: .amount)
    }

    /// The wallet whose saved address is in Send's field, this one too.
    private var matchedWallet: WalletInfo? {
        guard case .address = OpenAlias.classify(recipientInput),
              walletManager.isValidAddress(recipientInput) else { return nil }
        return WalletAddressMatch.wallet(
            for: recipientInput,
            wallets: walletManager.wallets,
            activeWalletId: walletManager.activeWallet?.id,
            activePrimaryAddress: walletManager.primaryAddress
        )
    }

    /// The contact whose address or OpenAlias name is in Send's field. A
    /// wallet match wins.
    private var matchedContact: Contact? {
        guard !isTransfer, !isLinkMode, matchedWallet == nil else { return nil }
        return ContactMatch.contact(forInput: recipientInput, in: contactStore.contacts)
    }

    /// Contacts under the field while it has text and no card.
    private var contactMatches: [Contact] {
        guard !isTransfer, !isLinkMode, matchedWallet == nil, matchedContact == nil else { return [] }
        return ContactMatch.matches(recipientInput, in: contactStore.contacts)
    }

    /// A contact from the Contacts sheet or under the field: its address or
    /// OpenAlias name fills the field, which shows the contact's card. A
    /// name is looked up at once, as Paste does.
    private func pickContact(_ contact: Contact) {
        isLinkMode = false
        recipientInput = contact.destination
        aliasLookup.submit(contact.destination)
    }

    /// The wallet the amount title and Review name: Transfer's pick, or
    /// the wallet whose address is in Send's field.
    private var walletRecipient: WalletInfo? {
        SendWalletRecipient.wallet(transferTarget: transferTarget, matched: matchedWallet, isTransfer: isTransfer, isLinkMode: isLinkMode)
    }

    /// From and To on the review of a send to one of your wallets.
    private var transferParties: TransferParties? {
        guard let to = walletRecipient, let from = walletManager.activeWallet else { return nil }
        return TransferParties(from: from, fromAddress: walletManager.primaryAddress, to: to)
    }

    /// A send that went out to one of this iPhone's wallets, this one too:
    /// History names it ("To Savings" here, "From Spending" there).
    private func recordWalletSend(txid: String) {
        guard let from = walletManager.activeWallet?.id,
              let to = WalletAddressMatch.wallet(
                for: recipientAddress,
                wallets: walletManager.wallets,
                activeWalletId: from,
                activePrimaryAddress: walletManager.primaryAddress
              ) else { return }
        SendRecordStore().record(SendRecord(txid: txid, fromWalletId: from, toWalletId: to.id))
    }

    // MARK: - Prefill

    private func handlePrefill() {
        // Transfer pays one of your wallets: nothing else fills it.
        guard !isTransfer else { return }
        if let request = walletManager.currentPaymentRequest() {
            apply(request, animated: false)
            return
        }

        if let addr = walletManager.prefillSendAddress {
            recipientAddress = addr
            recipientInput = addr
            // Filled in, not typed: its row shows at once.
            aliasLookup.submit(addr)
            aliasSummary = nil
            walletManager.prefillSendAddress = nil

            if let amt = walletManager.prefillSendAmount {
                amountString = amt
                walletManager.prefillSendAmount = nil
                jump(to: .review)
            } else {
                jump(to: .amount)
            }
        }
    }

    /// Fills the flow from a `monero:` link and stops on the amount step,
    /// never the review: the link is someone else's text, so the user
    /// confirms the amount before Send is one tap away.
    private func apply(_ request: WalletManager.PaymentRequest, animated: Bool) {
        shownPaymentRequest = request
        // A `monero:` link pays its address, not a payment link.
        isLinkMode = false
        recipientAddress = request.address
        recipientInput = request.address
        // Filled in, not typed: its row shows at once.
        aliasLookup.submit(request.address)
        aliasSummary = nil
        amountString = request.amount ?? ""
        amountPrefill = request.amount == nil ? nil : .paymentLink
        isSendingAll = false
        discardPreparedSend()

        guard phase != .amount else { return }
        if !animated {
            jump(to: .amount)
        } else if phase == .review {
            goBack(to: .amount)
        } else {
            goForward(to: .amount)
        }
    }

    // MARK: - Send

    /// Drops the review's signed transaction and its fee. A transaction
    /// never committed never reaches the network.
    private func discardPreparedSend() {
        preparedSend = nil
        estimatedFee = nil
    }

    /// The review's transaction pays what is on screen and can still be
    /// broadcast in the open wallet.
    private func preparedSendIsReady() async -> Bool {
        guard let prepared = preparedSend,
              SendReviewFee.matches(
                preparedAddress: prepared.address,
                preparedAmount: prepared.amount,
                preparedFee: prepared.fee,
                recipient: recipientAddress,
                amount: isSendingAll ? nil : Decimal(string: amountString)
              ) else { return false }
        return await walletManager.isPrepared(prepared)
    }

    private func sendTransaction() {
        if isLinkMode {
            sendLinkFunding()
            return
        }
        // Hardware wallets can't sign locally — hand off to the
        // hardware-session sheet which orchestrates BLE, sidecar key-
        // image sync, device-side signing, and broadcast. Bail out of
        // SendFlowView's local progress state since the sheet drives
        // its own UI from here.
        if walletManager.requiresHardwareSession {
            // Clear any leftover .complete/.failed state from the
            // prior run before opening the hardware sheet. See note
            // in WalletView's `onHardwareSyncTap` for why this lives
            // at the tap site and not in the sheet's `onAppear`.
            walletManager.clearTerminalSessionState()
            let trimmedMemo = memo.isEmpty ? nil : memo
            if isSendingAll {
                hardwareSheetIntent = .sendAll(to: recipientAddress, memo: trimmedMemo)
            } else if let amountDecimal = Decimal(string: amountString) {
                hardwareSheetIntent = .send(to: recipientAddress, amount: amountDecimal, memo: trimmedMemo)
            } else {
                // Release the guard before showing the error, or Retry on the
                // error screen is swallowed by `guard !sendInProgress`.
                sendInProgress = false
                phase = .error(message: String(localized: "Invalid amount"))
            }
            return
        }

        // The transaction the review built and showed, broadcast as it is.
        guard let prepared = preparedSend else {
            sendInProgress = false
            goBack(to: .review)
            return
        }
        Task {
            do {
                let txHash = try await walletManager.send(prepared)
                recordWalletSend(txid: txHash)
                sentAmount = SendReviewFee.xmr(prepared.amount)
                preparedSend = nil
                transactionHash = txHash
                await walletManager.refresh()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    phase = .success(txHash: txHash)
                }
                HapticFeedback.shared.transactionSuccess()
                SoundFeedback.shared.playSendComplete()
            } catch {
                sendInProgress = false
                let msg = friendlyErrorMessage(for: error)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    phase = .error(message: msg)
                }
                HapticFeedback.shared.error()
            }
        }
    }

    /// Funds the saved envelope: the amount plus the claim fee reserve, to
    /// the envelope address, through the normal send path.
    private func sendLinkFunding() {
        guard let linkRecordId, let record = EnvelopeStore.shared.record(id: linkRecordId, role: .sent) else {
            sendInProgress = false
            phase = .error(message: String(localized: "Could not make the payment link. Nothing was sent."))
            return
        }
        if walletManager.requiresHardwareSession {
            do {
                try PaymentLinkFunder.beginFunding(record, walletId: walletManager.activeWallet?.id.uuidString, networkType: walletManager.networkType)
            } catch {
                sendInProgress = false
                phase = .error(message: EnvelopeSession.message(for: error))
                return
            }
            walletManager.clearTerminalSessionState()
            walletManager.pendingBroadcastStep = PaymentLinkFunder.hardwareStep(id: record.id, address: record.address)
            hardwareSheetIntent = .send(
                to: record.address,
                amount: EnvelopeRuntime.xmr(record.amount + (record.feeReserve ?? 0)),
                memo: PaymentLinkFunder.memo
            )
            return
        }
        Task {
            do {
                let txHash = try await PaymentLinkFunder.fund(record, funding: linkFunding, walletManager: walletManager)
                transactionHash = txHash
                await walletManager.refresh()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    phase = .success(txHash: txHash)
                }
                HapticFeedback.shared.transactionSuccess()
                SoundFeedback.shared.playSendComplete()
            } catch {
                sendInProgress = false
                // A failed broadcast may still have reached the network.
                let msg: String
                if error is MoneroWallet.BroadcastCancelled {
                    msg = String(localized: "Could not make the payment link. Nothing was sent.")
                } else if case MoneroCoreError.transactionCommitFailed = error {
                    msg = PaymentLinkFunder.unconfirmedMessage
                } else {
                    msg = friendlyErrorMessage(for: error)
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    phase = .error(message: msg)
                }
                HapticFeedback.shared.error()
            }
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        if let coreError = error as? MoneroCoreError {
            switch coreError {
            case .walletNotInitialized:
                return String(localized: "Wallet not ready. Please wait for sync to complete.")
            case .walletStatusError(let msg):
                return msg ?? String(localized: "Wallet error occurred.")
            case .insufficientFunds(let balance):
                return String(localized: "Not enough unlocked funds. Available: \(balance) XMR")
            case .transactionEstimationFailed(let msg):
                return msg
            case .transactionSendFailed(let msg):
                return msg
            case .transactionCommitFailed(let msg):
                return String(localized: "Broadcast failed: \(msg)")
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Phase helpers

extension SendFlowPhase {
    var isSendingState: Bool {
        if case .sending = self { return true }
        return false
    }

    /// True before the user confirms. From `.sending` on, a new payment link
    /// must not touch the flow.
    var acceptsPaymentRequest: Bool {
        switch self {
        case .address, .amount, .review: return true
        case .sending, .success, .error: return false
        }
    }
}

// MARK: - Presenting

/// Opens the send sheet when something outside the dashboard asks for it:
/// Donate, or a `monero:` link. It reads the request on appear as well as on
/// change, because a link that arrives with the unlock builds the dashboard
/// with the flag already set, and `onChange` only sees later changes.
struct SendRequestPresenter: ViewModifier {
    @ObservedObject var walletManager: WalletManager
    @Binding var showSend: Bool

    func body(content: Content) -> some View {
        content
            .onAppear(perform: present)
            .onChange(of: walletManager.shouldShowSendView) { _, _ in present() }
    }

    private func present() {
        guard walletManager.shouldShowSendView else { return }
        walletManager.shouldShowSendView = false
        // A link while another sheet is up: sheets that hold no work close
        // themselves (`closesForPaymentLink`), then Send opens. Anything
        // else (a hardware session, Add Wallet, a form) stays, and the link
        // waits for the next Send as before. Send open handles the link
        // itself.
        guard walletManager.currentPaymentRequest() != nil,
              !walletManager.isSendFlowPresented,
              Self.isSheetShowing else {
            showSend = true
            return
        }
        NotificationCenter.default.post(name: .paymentLinkClosesSheets, object: nil)
        Task { @MainActor in
            // Until the sheet is gone (its dismissal animates), at most 3 s.
            var waited = 0
            while Self.isSheetShowing, waited < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            showSend = true
        }
    }

    /// True while anything is presented over the app's root screen.
    @MainActor
    static var isSheetShowing: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
}

extension Notification.Name {
    /// A good `monero:` link needs the screen for Send.
    static let paymentLinkClosesSheets = Notification.Name("one.monero.paymentLinkClosesSheets")
}

/// Closes the sheet it is on when a payment link needs the screen for Send.
private struct ClosesForPaymentLink: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .paymentLinkClosesSheets)) { _ in
                dismiss()
            }
    }
}

extension View {
    func presentsSendRequests(from walletManager: WalletManager, showSend: Binding<Bool>) -> some View {
        modifier(SendRequestPresenter(walletManager: walletManager, showSend: showSend))
    }

    /// For the root of a sheet with nothing to lose (Receive, a chart, a
    /// transaction): a payment link closes it and opens Send.
    func closesForPaymentLink() -> some View {
        modifier(ClosesForPaymentLink())
    }
}

#Preview {
    SendFlowView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
