import SwiftUI
import MoneroKit

struct SendReviewStep: View {
    let recipientAddress: String
    /// Set when the recipient came from an OpenAlias name.
    var aliasSummary: OpenAliasSummary? = nil
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 16)

                    // Transaction card
                    VStack(spacing: 0) {
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
                                    if let recipientName = aliasSummary.recipientName {
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
                            } else {
                                ReviewValuePlaceholder(sample: ReviewValuePlaceholder.feeSample, priceService: priceService)
                            }
                        }
                        .font(.subheadline)
                        .padding()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(estimatedFee.map { String(localized: "Network fee: \(XMRFormatter.format($0)) XMR") } ?? String(localized: "Network fee: loading"))

                        // Total. Its row holds its place until the value is known.
                        Divider().padding(.horizontal)

                        HStack {
                            Text("Total")
                                .fontWeight(.semibold)
                            Spacer()
                            if let total = total {
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
                            } else {
                                ReviewValuePlaceholder(sample: amount > 0 ? amount : walletManager.displayUnlockedBalance, priceService: priceService, weight: .semibold)
                            }
                        }
                        .font(.subheadline)
                        .padding()

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
            return Text("Recipient: \(aliasSummary.spokenName), address \(recipientAddress)")
        }
        return Text("Recipient: \(recipientAddress)")
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

    let sample: Decimal
    let priceService: PriceService
    var weight: Font.Weight = .medium

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(XMRFormatter.format(sample)) XMR")
                .fontWeight(weight)
            if let fiat = priceService.formatFiatValue(sample) {
                Text("≈ \(fiat)")
                    .font(.caption)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
