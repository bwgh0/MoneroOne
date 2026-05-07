import SwiftUI
import MoneroKit

/// Sheet that drives a hardware session and renders progress.
///
/// Lifecycle:
/// 1. User taps Sync banner / pill / Send-Confirm → sheet presents.
/// 2. Sheet observes `walletManager.trezorManager` for BLE state. When
///    state hits `.bridgeRunning` (after pair / handshake / pairing-code),
///    sheet kicks off `walletManager.runHardware{Sync,Send}Session`.
/// 3. Sheet observes `walletManager.hardwareSessionState` for the
///    open-FULL → refresh → coldKeyImageSync → (send) → snapshot →
///    teardown lifecycle. Renders the right copy/spinner per phase.
/// 4. On `.complete`/`.failed`, sheet shows result + Done button.
///    Dismiss calls `walletManager.resetHardwareSessionState()`.
struct HardwareSessionSheet: View {
    enum Intent: Identifiable, Equatable {
        case syncSentTransactions
        case send(to: String, amount: Decimal, memo: String?)
        case sendAll(to: String, memo: String?)

        var id: String {
            switch self {
            case .syncSentTransactions: return "sync"
            case .send(let to, let amount, _): return "send-\(to)-\(amount)"
            case .sendAll(let to, _): return "sendAll-\(to)"
            }
        }
    }

    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    let intent: Intent

    /// Direct subscription to the long-lived `WalletManager.trezorManager`.
    /// Same observation gotcha that bit PairTrezorView — a computed
    /// property off the env object would silently miss every state
    /// change. Inject + observe explicitly.
    @ObservedObject var trezorManager: TrezorManager

    @State private var pairingCodeInput: String = ""
    @State private var pairingCodeSubmitted: Bool = false
    @FocusState private var pairingCodeFocused: Bool

    /// Set once we transition the WalletManager session driver from
    /// `.idle` to a real run, so a SwiftUI rebuild doesn't fire it twice.
    @State private var sessionStarted: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer().frame(height: 8)
                content
                Spacer()
                bottomActions
            }
            .padding()
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Keep dismiss disabled across the whole lifecycle. When
            // we toggled this on `.complete`, SwiftUI tore down the
            // hosting view + represented a fresh sheet instance,
            // which fired `onAppear` → `evaluateBleState` → spawned
            // a duplicate session Task that ran the moment the
            // first one set state back to `.idle`. Locking it true
            // pins the sheet through the entire session including
            // the success view; the user dismisses via Done/Cancel.
            .interactiveDismissDisabled(true)
            .onAppear { startBleIfNeeded() }
            .onChange(of: trezorManager.state) { _, _ in
                evaluateBleState()
            }
            .onChange(of: walletManager.hardwareSessionState) { _, newState in
                handleSessionStateChange(newState)
            }
            .onDisappear {
                // If the user ditched mid-session, drop BLE so the
                // session cleans up. After a successful session we
                // keep the connection alive for the warm window so a
                // follow-up Sync/Send can fast-path through BLE
                // bringup — WalletManager's `scheduleWarmConnectionDisconnect`
                // takes care of eventual teardown.
                if isInProgress {
                    walletManager.disconnectHardwareDevice()
                }
                // Don't `resetHardwareSessionState()` here. SwiftUI
                // fires `.onDisappear` not just on real user dismiss
                // but during view-graph teardown that races with the
                // `.complete` transition (the modal sheet auto-tears
                // when `interactiveDismissDisabled` flips false on
                // `.complete`). Resetting state to `.idle` from here
                // let the duplicate `runHardwareSession` Task — the
                // one queued behind T1 on @MainActor — pass the
                // idle-only guard and tear down the warm window.
                // Terminal states get cleared at the start of the
                // next sync/send instead (see WalletManager
                // `clearTerminalSessionState`).
            }
        }
    }

    // MARK: - Content router

    private var navTitle: String {
        switch intent {
        case .syncSentTransactions: return "Sync Sent Transactions"
        case .send, .sendAll: return "Sign with Trezor"
        }
    }

    private var isInProgress: Bool {
        switch walletManager.hardwareSessionState {
        case .complete, .failed, .idle: return false
        default: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch walletManager.hardwareSessionState {
        case .idle:
            // Pre-session: drive BLE bringup ourselves.
            bleBringupContent
        case .connecting:
            simpleProgress(title: "Preparing session…", subtitle: nil)
        case .openingFull:
            simpleProgress(
                title: "Opening device wallet…",
                subtitle: "Confirm prompts on your Trezor as they appear."
            )
        case .syncingFull(let progress, let blocksRemaining):
            syncingProgress(progress: progress, blocksRemaining: blocksRemaining)
        case .syncingKeyImages:
            simpleProgress(
                title: "Reading transactions from Trezor…",
                subtitle: "Confirm the key-image sync prompt on your device."
            )
        case .signing:
            simpleProgress(
                title: "Confirm on your Trezor",
                subtitle: "Review the transaction details on the device screen."
            )
        case .broadcasting:
            simpleProgress(title: "Broadcasting…", subtitle: nil)
        case .tearingDown:
            simpleProgress(title: "Restoring wallet…", subtitle: nil)
        case .complete(let message):
            successContent(message: message)
        case .failed(let message):
            failureContent(message: message)
        }
    }

    @ViewBuilder
    private var bleBringupContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            switch trezorManager.state {
            case .idle, .scanning:
                Text("Searching for your Trezor…")
                    .font(.headline)
                Text("Make sure the device is unlocked and Bluetooth is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !trezorManager.discoveredDevices.isEmpty {
                    deviceList
                } else {
                    ProgressView().padding(.top, 4)
                }
            case .connecting:
                progressLabel("Connecting…")
            case .connected, .allocatingTHP, .handshaking:
                progressLabel("Setting up encrypted channel…")
            case .pairing:
                if trezorManager.pairingCodeRequired {
                    pairingCodeEntry
                } else {
                    progressLabel("Verifying pairing code…")
                }
            case .bridgeRunning:
                progressLabel("Ready, starting session…")
            case .error(let msg):
                inlineError(msg)
            }
        }
    }

    private var deviceList: some View {
        VStack(spacing: 8) {
            ForEach(trezorManager.discoveredDevices) { device in
                Button {
                    trezorManager.connect(to: device)
                } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                        Text(device.name)
                            .font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pairingCodeEntry: some View {
        VStack(spacing: 16) {
            Text("Enter the 6-digit code shown on your Trezor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("000000", text: $pairingCodeInput)
                .keyboardType(.numberPad)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .focused($pairingCodeFocused)
                .onChange(of: pairingCodeInput) { _, newValue in
                    let trimmed = String(newValue.prefix(6))
                    if trimmed != newValue {
                        pairingCodeInput = trimmed
                    }
                    if trimmed.count == 6, !pairingCodeSubmitted {
                        pairingCodeSubmitted = true
                        trezorManager.submitPairingCode(trimmed)
                    }
                }
            if pairingCodeSubmitted {
                Text("Verifying…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pairingCodeFocused = true
            }
        }
    }

    private func progressLabel(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func simpleProgress(title: String, subtitle: String?) -> some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4).padding(.bottom, 4)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func syncingProgress(progress: Double, blocksRemaining: Int?) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress / 100)
                .progressViewStyle(.linear)
                .tint(.orange)
                .padding(.horizontal, 24)
            Text("Syncing device wallet")
                .font(.headline)
            if let blocksRemaining, blocksRemaining > 0 {
                Text("\(Int(progress))% — \(blocksRemaining) blocks remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(progress))% synced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("First-time sync can take a few minutes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private func successContent(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Done")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func failureContent(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Couldn't complete")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Couldn't connect")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var bottomActions: some View {
        switch walletManager.hardwareSessionState {
        case .complete:
            Button {
                walletManager.resetHardwareSessionState()
                dismiss()
            } label: {
                Text("Done")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14))
            }
        case .failed:
            HStack(spacing: 12) {
                Button {
                    walletManager.resetHardwareSessionState()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    walletManager.resetHardwareSessionState()
                    sessionStarted = false
                    pairingCodeSubmitted = false
                    startBleIfNeeded()
                } label: {
                    Text("Try Again")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        default:
            Button(role: .cancel) {
                cancelAndDismiss()
            } label: {
                Text("Cancel")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Lifecycle

    private func startBleIfNeeded() {
        if case .bridgeRunning = trezorManager.state {
            evaluateBleState()
            return
        }
        trezorManager.startScanning()
    }

    /// When BLE reaches `.bridgeRunning`, kick off the WalletManager
    /// session driver. Guarded by `sessionStarted` so a re-render
    /// doesn't fire it twice.
    private func evaluateBleState() {
        guard !sessionStarted else { return }
        guard case .bridgeRunning = trezorManager.state else { return }
        sessionStarted = true
        Task { await runIntent() }
    }

    @MainActor
    private func runIntent() async {
        switch intent {
        case .syncSentTransactions:
            await walletManager.runHardwareSyncSession()
        case .send(let to, let amount, let memo):
            _ = await walletManager.runHardwareSendSession(to: to, amount: amount, memo: memo)
        case .sendAll(let to, let memo):
            _ = await walletManager.runHardwareSendAllSession(to: to, memo: memo)
        }
        // After the session driver returns, `hardwareSessionState`
        // is `.complete` or `.failed`. The view re-renders via the
        // onChange observer; nothing more to do here.
    }

    private func handleSessionStateChange(_ state: WalletManager.HardwareSessionState) {
        // Don't drop BLE on failure. The previous "clean slate"
        // behavior dropped the link on .failed and the user had to
        // re-discover/reconnect from scratch — even when the failure
        // was wallet-side (insufficient funds, daemon timeout, etc.)
        // and BLE was perfectly healthy. With skip-pair working, we
        // can safely keep the warm window alive across failures so
        // a Try Again retry fast-paths through bringup. The
        // warm-window timer on WalletManager handles eventual
        // teardown either way.
        _ = state
    }

    private func cancelAndDismiss() {
        walletManager.resetHardwareSessionState()
        walletManager.disconnectHardwareDevice()
        dismiss()
    }
}
