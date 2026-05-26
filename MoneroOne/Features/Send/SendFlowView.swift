import SwiftUI
import MoneroKit

struct SendFlowView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var phase: SendFlowPhase = .address
    @State private var navigatingForward = true

    // Send data
    @State private var recipientAddress = ""
    @State private var amountString = ""
    @State private var memo = ""
    @State private var isSendingAll = false
    @State private var estimatedFee: Decimal?
    @State private var transactionHash: String?

    // UI state
    @State private var showScanner = false
    @State private var sendInProgress = false
    @State private var amountPrefilledFromQR = false

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

    var body: some View {
        NavigationStack {
            ZStack {
                if canSign {
                    phaseContent
                        .id(phaseIndex)
                        .transition(.asymmetric(
                            insertion: .move(edge: navigatingForward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: navigatingForward ? .leading : .trailing).combined(with: .opacity)
                        ))
                } else {
                    viewOnlyBlockedView
                }
            }
            .clipped()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !canSign {
                        Button("Close") { dismiss() }
                    } else {
                        switch phase {
                        case .address:
                            Button("Cancel") { dismiss() }
                        case .amount:
                            Button {
                                HapticFeedback.shared.buttonPress()
                                goBack(to: .address)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                            }
                        case .review:
                            Button {
                                HapticFeedback.shared.buttonPress()
                                goBack(to: .amount)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scannedAddress, scannedAmount in
                    recipientAddress = scannedAddress
                    if let amount = scannedAmount {
                        amountString = amount
                        amountPrefilledFromQR = true
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase.isSendingState)
        .onAppear {
            handlePrefill()
        }
        .sheet(item: $hardwareSheetIntent, onDismiss: handleHardwareSheetDismiss) { intent in
            HardwareSessionSheet(
                intent: intent,
                trezorManager: walletManager.trezorManager
            )
            .environmentObject(walletManager)
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
        Task {
            await walletManager.refresh()
            await MainActor.run {
                switch outcome {
                case .sentTransaction(let txId):
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
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                phase = .success(txHash: txId)
                            }
                        }
                    }
                case .failed:
                    sendInProgress = false
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        phase = .review
                    }
                case .syncedOnly, .none:
                    // No send actually ran — leave the user where
                    // they are.
                    break
                }
            }
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .address:
            SendAddressStep(
                recipientAddress: $recipientAddress,
                showScanner: $showScanner,
                isConnected: networkMonitor.isConnected,
                isValidAddress: walletManager.isValidAddress(recipientAddress),
                onContinue: {
                    HapticFeedback.shared.buttonPress()
                    goForward(to: .amount)
                }
            )

        case .amount:
            SendAmountStep(
                amountString: $amountString,
                memo: $memo,
                isSendingAll: $isSendingAll,
                recipientAddress: recipientAddress,
                unlockedBalance: walletManager.displayUnlockedBalance,
                priceService: priceService,
                amountPrefilledFromQR: amountPrefilledFromQR,
                onContinue: {
                    HapticFeedback.shared.buttonPress()
                    goForward(to: .review)
                }
            )

        case .review:
            SendReviewStep(
                recipientAddress: recipientAddress,
                amountString: amountString,
                memo: memo,
                isSendingAll: isSendingAll,
                estimatedFee: $estimatedFee,
                priceService: priceService,
                walletManager: walletManager,
                sendInProgress: sendInProgress,
                onConfirm: {
                    guard !sendInProgress else { return }
                    sendInProgress = true
                    HapticFeedback.shared.sendInitiated()
                    goForward(to: .sending)
                    sendTransaction()
                },
                onUpgradeToSendAll: {
                    isSendingAll = true
                }
            )

        case .sending, .success, .error:
            SendStatusStep(
                phase: phase,
                amountString: amountString,
                priceService: priceService,
                onDone: { dismiss() },
                onRetry: {
                    guard !sendInProgress else { return }
                    sendInProgress = true
                    goForward(to: .sending)
                    sendTransaction()
                },
                onClose: { dismiss() }
            )
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
                .foregroundStyle(.orange)

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

    private var phaseIndex: Int {
        switch phase {
        case .address: return 0
        case .amount: return 1
        case .review: return 2
        case .sending, .success, .error: return 3
        }
    }

    private func goForward(to newPhase: SendFlowPhase) {
        navigatingForward = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            phase = newPhase
        }
    }

    private func goBack(to newPhase: SendFlowPhase) {
        navigatingForward = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            phase = newPhase
        }
    }

    // MARK: - Prefill

    private func handlePrefill() {
        if let addr = walletManager.prefillSendAddress {
            recipientAddress = addr
            walletManager.prefillSendAddress = nil

            if let amt = walletManager.prefillSendAmount {
                amountString = amt
                walletManager.prefillSendAmount = nil
                phase = .review
            } else {
                phase = .amount
            }
        }
    }

    // MARK: - Send

    private func sendTransaction() {
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
                phase = .error(message: "Invalid amount")
            }
            return
        }

        Task {
            do {
                let txHash: String
                if isSendingAll {
                    txHash = try await walletManager.sendAll(
                        to: recipientAddress,
                        memo: memo.isEmpty ? nil : memo
                    )
                } else {
                    guard let amountDecimal = Decimal(string: amountString) else {
                        phase = .error(message: "Invalid amount")
                        return
                    }
                    txHash = try await walletManager.send(
                        to: recipientAddress,
                        amount: amountDecimal,
                        memo: memo.isEmpty ? nil : memo
                    )
                }
                transactionHash = txHash
                await walletManager.refresh()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    phase = .success(txHash: txHash)
                }
                HapticFeedback.shared.transactionSuccess()
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

    private func friendlyErrorMessage(for error: Error) -> String {
        if let coreError = error as? MoneroCoreError {
            switch coreError {
            case .walletNotInitialized:
                return "Wallet not ready. Please wait for sync to complete."
            case .walletStatusError(let msg):
                return msg ?? "Wallet error occurred."
            case .insufficientFunds(let balance):
                return "Not enough unlocked funds. Available: \(balance) XMR"
            case .transactionEstimationFailed(let msg):
                return msg
            case .transactionSendFailed(let msg):
                return msg
            case .transactionCommitFailed(let msg):
                return "Broadcast failed: \(msg)"
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
}

#Preview {
    SendFlowView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
