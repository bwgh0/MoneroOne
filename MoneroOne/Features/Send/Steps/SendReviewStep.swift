import SwiftUI
import MoneroKit

struct SendReviewStep: View {
    let recipientAddress: String
    /// Set when the recipient came from an OpenAlias name.
    var aliasSummary: OpenAliasSummary? = nil
    /// A transfer between your wallets: From over To in place of the
    /// recipient.
    var transfer: TransferParties? = nil
    /// The saved contact this send goes to: its name heads the recipient.
    var contact: Contact? = nil
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
    /// A failed build offers Retry, except for a lack of funds.
    @State private var feeErrorCanRetry = true
    @State private var showContent = false
    @State private var upgradedToSendAll = false
    /// The review waits for a running, synced wallet before it builds.
    @State private var isWaitingForSync = true
    /// The wait passed half a second: the status slot above Send shows.
    @State private var isWaitShown = false
    /// Bumped by Retry: the review waits and builds again.
    @State private var retry = 0
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

    /// An amount in the order Fiat Mode picks.
    private func lines(_ xmr: Decimal) -> ReviewAmountLines {
        ReviewAmountLines(xmr: xmr, priceService: priceService)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 16)

                    // Transaction card
                    VStack(spacing: 0) {
                        if let transfer {
                            walletRow(transfer.from, address: transfer.fromAddress, label: String(localized: "From", comment: "Transfer review: the wallet that sends"))
                            Divider().padding(.horizontal)
                            walletRow(
                                transfer.to,
                                address: recipientAddress,
                                label: String(localized: "To", comment: "Transfer review: the wallet that receives"),
                                name: transfer.isToSelf ? String(localized: "This Wallet", comment: "Transfer: the current wallet as a destination") : nil
                            )
                        } else if let contact, aliasSummary == nil {
                            contactRow(contact)
                        } else {
                        // Recipient. A name shows its picture, the name,
                        // the OpenAlias name and every character of the address.
                        HStack(alignment: aliasSummary == nil ? .center : .top, spacing: 12) {
                            if let aliasSummary {
                                RecipientAvatar(summary: aliasSummary, diameter: 40)
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(Color.brand.opacity(0.15))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.brand)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recipient")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let aliasSummary {
                                    if let recipientName = contact?.name ?? aliasSummary.recipientName {
                                        Text(verbatim: recipientName)
                                            .font(.headline)
                                        OpenAliasNameText(name: aliasSummary.name.display)
                                    } else {
                                        OpenAliasNameText(name: aliasSummary.name.display, style: .headline, weight: .semibold, color: .label)
                                    }
                                    CodeText(recipientAddress, color: .label)
                                        .padding(.top, 4)
                                } else {
                                    CodeText(formatAddress(recipientAddress), color: .label)
                                }
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
                        }

                        Divider().padding(.horizontal)

                        // Amount
                        VStack(spacing: 4) {
                            if isSendingAll || upgradedToSendAll {
                                Text("All Funds")
                                    .font(.title.weight(.bold))
                                if let fee = estimatedFee {
                                    let sendAmount = preparedSend.map { SendReviewFee.xmr($0.amount) }
                                        ?? walletManager.displayUnlockedBalance - fee
                                    let sent = lines(sendAmount)
                                    Text(verbatim: sent.primary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let secondary = sent.secondary {
                                        Text(verbatim: secondary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                let sent = lines(amount)
                                Text(verbatim: sent.primary)
                                    .font(.title.weight(.bold))
                                if let secondary = sent.secondary {
                                    Text(verbatim: secondary)
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
                                let feeLines = lines(fee)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: feeLines.primary)
                                        .fontWeight(.medium)
                                    if let secondary = feeLines.secondary {
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
                        .accessibilityLabel(estimatedFee.map { SendReviewFee.accessibilityLabel(fee: $0, lines: lines($0)) } ?? String(localized: "Network fee: loading"))

                        // Total. Its row holds its place until the value is known.
                        // A send back to this wallet has no total: only the
                        // fee leaves it.
                        if transfer?.isToSelf != true {
                            Divider().padding(.horizontal)

                            HStack {
                                Text("Total")
                                    .fontWeight(.semibold)
                                Spacer()
                                if let total = total {
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
                                    ReviewValuePlaceholder(lines: lines(amount > 0 ? amount : walletManager.displayUnlockedBalance), weight: .semibold)
                                }
                            }
                            .font(.subheadline)
                            .padding()
                        }

                        // The description in the OpenAlias record.
                        if let txDescription = aliasSummary?.txDescription {
                            Divider().padding(.horizontal)

                            OpenAliasDescriptionRow(text: txDescription)
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

                    // A send back to this wallet: what it does, 8 pt under
                    // the card.
                    if transfer?.isToSelf == true {
                        Text("Sends XMR back to this wallet as a new payment. You can spend it again in about 20 minutes.", comment: "Transfer: the footer under From and To when the XMR goes back to the same wallet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, -12)
                    }
                }
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Send button, with the wallet's status or a failed build above it
            VStack(spacing: 10) {
                SendWaitStatus(
                    walletManager: walletManager,
                    failure: feeError,
                    failureCanRetry: feeErrorCanRetry,
                    isWaitShown: isWaitShown,
                    onRetry: {
                        // A failed build builds again; a wait asks the node again.
                        if feeError != nil { retry += 1 } else { Task { await walletManager.refresh() } }
                    }
                )

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
                .accessibilityHint(sendHint)
            }
            .padding()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .task(id: [rebuild, retry]) {
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
    private var sendHint: Text {
        if estimatedFee != nil { return Text("Double tap to send \(XMRFormatter.format(amount)) XMR") }
        return isWaitingForSync ? Text("Waiting for your wallet to sync", comment: "VoiceOver hint on the gray Send button while Review waits for the wallet to sync") : Text("Waiting for fee estimate")
    }

    /// Waits for a running, synced wallet (a payment-link check gives it
    /// back at once), then builds. The status slot shows only when the
    /// wait takes a moment, and stays until the values are in.
    private func loadFee() async {
        feeError = nil
        estimatedFee = nil
        preparedSend = nil
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
        await build()
        guard !Task.isCancelled else { return }
        withAnimation(SendWaitRules.crossFade) { isWaitShown = false }
    }

    private func fail(_ error: Error) {
        withAnimation(SendWaitRules.crossFade) {
            feeErrorCanRetry = SendWaitRules.canRetry(after: error)
            feeError = error.localizedDescription
        }
    }

    private func build() async {
        guard !walletManager.requiresHardwareSession else {
            do {
                let fee = try await walletManager.estimateFee(to: recipientAddress, amount: amount)
                guard !Task.isCancelled else { return }
                withAnimation(SendWaitRules.crossFade) { estimatedFee = fee }

                // If amount + fee exceeds balance, auto-upgrade to send all
                if amount + fee > walletManager.displayUnlockedBalance, !isSendingAll {
                    upgradedToSendAll = true
                    onUpgradeToSendAll?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
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
            withAnimation(SendWaitRules.crossFade) {
                preparedSend = prepared
                estimatedFee = SendReviewFee.xmr(prepared.fee)
            }
        } catch {
            guard !Task.isCancelled else { return }
            fail(error)
        }
    }

    private var recipientLabel: Text {
        if let aliasSummary {
            if let contact {
                return Text("Recipient: \(contact.name), \(aliasSummary.spokenName), address \(recipientAddress)")
            }
            return Text("Recipient: \(aliasSummary.spokenName), address \(recipientAddress)")
        }
        return Text("Recipient: \(recipientAddress)")
    }

    private func formatAddress(_ addr: String) -> String {
        ReceiveAddressLogic.shortAddress(addr)
    }

    /// A saved contact, in the wallet row's form: its monogram,
    /// "Recipient", its name and its 8…8 address.
    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            RecipientMonogram(initials: contact.initials, diameter: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recipient")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: contact.name)
                    .font(.headline)
                    .lineLimit(1)
                CodeText(formatAddress(recipientAddress), color: .label)
            }

            Spacer()
        }
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recipient: \(contact.name), \(formatAddress(recipientAddress))"))
        .accessibilityIdentifier("send.review.contact")
    }

    /// One of your wallets on a transfer's review: its emoji, "From" or
    /// "To", its name ("This Wallet" for a send back to it) and its 8…8
    /// address.
    private func walletRow(_ wallet: WalletInfo, address: String, label: String, name: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(wallet.emoji)
                .font(.system(size: 22))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(name ?? wallet.name)
                    .font(.headline)
                    .lineLimit(1)
                CodeText(formatAddress(address), color: .label)
            }

            Spacer()
        }
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label): \(name ?? wallet.name), \(formatAddress(address))"))
    }
}

/// The two wallets of a transfer, for its review.
struct TransferParties {
    let from: WalletInfo
    let fromAddress: String
    let to: WalletInfo

    /// A send back to the wallet it leaves (This Wallet).
    var isToSelf: Bool { from.id == to.id }
}

/// A Review amount in the order Fiat Mode picks. Fiat Mode with a usable
/// price: the fiat value on top and the exact XMR under it, like every
/// amount in Fiat Mode (the sending step too). Otherwise the XMR on top and
/// "≈ fiat" under it.
struct ReviewAmountLines: Equatable {
    let primary: String
    /// Nil with no price.
    let secondary: String?
    /// The fiat value is on top.
    let isFiatFirst: Bool

    static func fiatFirst(fiatMode: Bool, price: Double?) -> Bool {
        guard fiatMode, let price else { return false }
        return PriceService.isPlausiblePrice(price)
    }

    init(xmr: Decimal, fiat: String?, fiatFirst: Bool) {
        let xmrText = "\(XMRFormatter.format(xmr)) XMR"
        if fiatFirst, let fiat {
            primary = fiat
            secondary = xmrText
            isFiatFirst = true
        } else {
            primary = xmrText
            secondary = fiat.map { "≈ \($0)" }
            isFiatFirst = false
        }
    }

    /// The order the current Fiat Mode and price pick (both Reviews).
    @MainActor
    init(xmr: Decimal, priceService: PriceService) {
        self.init(xmr: xmr, fiat: priceService.formatFiatValue(xmr),
                  fiatFirst: Self.fiatFirst(fiatMode: priceService.showFiatFirst,
                                            price: priceService.xmrPrice))
    }

    /// What VoiceOver reads for a value shown fiat first: the fiat value,
    /// then the exact XMR, as on the screen. Nil when XMR is on top: those
    /// labels read the XMR alone, as before.
    var spokenFiatFirst: String? {
        guard isFiatFirst, let secondary else { return nil }
        return "\(primary), \(secondary)"
    }
}

/// The review's fee rules, apart from the view so tests can pin them.
enum SendReviewFee {
    /// VoiceOver's fee label, in the order of the screen: in Fiat Mode the
    /// fiat value, then the exact XMR. Otherwise the XMR alone.
    static func accessibilityLabel(fee: Decimal, lines: ReviewAmountLines) -> String {
        if let spoken = lines.spokenFiatFirst {
            return String(localized: "Network fee: \(spoken)", comment: "VoiceOver, Review in Fiat Mode: the network fee in fiat, then the exact XMR, e.g. \"$0.01, 0.00003152 XMR\"")
        }
        return String(localized: "Network fee: \(XMRFormatter.format(fee)) XMR")
    }

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

/// Review waits for a running, synced wallet before it builds, on every
/// send path. The rules, apart from the views so tests can pin them.
enum SendWaitRules {
    /// A wait shorter than this shows no status, so a ready wallet shows no flash.
    static let slotDelay: Duration = .milliseconds(500)
    static let crossFade: Animation = .easeInOut(duration: 0.35)

    /// The review builds only on a running wallet that wallet2 reports
    /// synced at a known chain tip. Syncing is not enough: wallet2 can
    /// refuse to build until it is synced.
    static func isReady(walletRunning: Bool, walletState: MoneroWallet.SyncState, daemonHeight: UInt64, syncBlocked: Bool) -> Bool {
        guard walletRunning, !syncBlocked, daemonHeight > 0 else { return false }
        return walletState == .synced
    }

    /// The step of a wallet that starts again while the balance card still
    /// holds "Synced". Only wallet2's own state counts: the heights from
    /// before the restart say nothing about where the wallet is now, so a
    /// wallet that is not scanning yet is still connecting.
    static func stage(walletState: MoneroWallet.SyncState, daemonHeight: UInt64) -> ConnectionStage {
        switch walletState {
        case .synced:
            return daemonHeight > 0 ? .synced : .connecting
        case .syncing:
            return .syncing
        case .idle, .connecting, .error:
            return .connecting
        }
    }

    /// What the slot above Send shows.
    enum Slot: Equatable {
        case none
        /// The balance card's steps; "Synced" while the review builds.
        case progress
        case paused
        case offline
        /// The network is up and the wallet cannot reach its node.
        case nodeUnreachable
        /// The build failed.
        case failed(String, canRetry: Bool)
    }

    /// A failed build always shows. A wait shows once it passed `slotDelay`.
    static func slot(failure: String?, failureCanRetry: Bool, isWaitShown: Bool,
                     isConnected: Bool, syncBlocked: Bool, syncFailed: Bool) -> Slot {
        if let failure { return .failed(failure, canRetry: failureCanRetry) }
        guard isWaitShown else { return .none }
        if !isConnected { return .offline }
        if syncBlocked { return .paused }
        if syncFailed { return .nodeUnreachable }
        return .progress
    }

    /// A failed build offers Retry, except for a lack of funds: the review
    /// offers All Funds for that, as before.
    static func canRetry(after error: Error) -> Bool {
        if SendReviewFee.isNotEnoughMoney(error) { return false }
        if case PaymentLinkFunder.FundingError.insufficientFunds = error { return false }
        return true
    }
}

/// The slot directly above Send on Review: where the wallet is while the
/// review waits for it, or why the build failed.
struct SendWaitStatus: View {
    @ObservedObject var walletManager: WalletManager
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    let failure: String?
    let failureCanRetry: Bool
    let isWaitShown: Bool
    let onRetry: () -> Void

    private var slot: SendWaitRules.Slot {
        var syncFailed = false
        if case .error = walletManager.syncState { syncFailed = true }
        return SendWaitRules.slot(
            failure: failure,
            failureCanRetry: failureCanRetry,
            isWaitShown: isWaitShown,
            isConnected: networkMonitor.isConnected,
            syncBlocked: walletManager.isSyncBlocked,
            syncFailed: syncFailed
        )
    }

    var body: some View {
        Group {
            switch slot {
            case .none:
                EmptyView()
            case .progress:
                ConnectionStepIndicator(stage: walletManager.sendWaitStage, syncProgress: walletManager.sendWaitProgress)
            case .paused:
                HStack {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Paused")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Sync status: paused")
                }
            case .offline:
                ErrorBanner(message: String(localized: "No internet connection"), type: .offline, retryAction: onRetry)
            case .nodeUnreachable:
                ErrorBanner(
                    message: String(localized: "Could not reach the node. Check your connection and try again."),
                    type: .error,
                    retryAction: onRetry
                )
            case .failed(let message, let canRetry):
                ErrorBanner(message: message, type: .error, retryAction: canRetry ? onRetry : nil)
            }
        }
        .transition(.opacity)
    }
}

/// A review value that is not known yet: gray bars the size of the value
/// and its fiat line, so nothing moves when it fills in. VoiceOver skips
/// them; the row says it is loading.
struct ReviewValuePlaceholder: View {
    /// A typical network fee, for the bars' width.
    static let feeSample = Decimal(string: "0.00003152") ?? 0

    /// A sample amount in the order Fiat Mode picks.
    let lines: ReviewAmountLines
    var weight: Font.Weight = .medium

    init(lines: ReviewAmountLines, weight: Font.Weight = .medium) {
        self.lines = lines
        self.weight = weight
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: lines.primary)
                .fontWeight(weight)
            if let secondary = lines.secondary {
                Text(verbatim: secondary)
                    .font(.caption)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
