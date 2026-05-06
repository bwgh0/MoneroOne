import SwiftUI
import MoneroKit

/// Sheet that drives a single TrezorSession from start to finish.
///
/// Two intents:
///   - `.syncSentTransactions` — runs the cold-key-image sync only. Tap
///     trigger comes from the BalanceCard pill / banner. After success
///     stamps `WalletManager.markHardwareSentSyncCompleted()` so the
///     "Last synced X ago" subtitle updates.
///   - `.send(...)` — runs key-image sync + sign + broadcast. Trigger
///     comes from the SendFlow's confirm button when the active wallet
///     `requiresHardwareSession`.
///
/// Reuses the BLE / THP scaffolding from PairTrezorView via the same
/// long-lived `WalletManager.trezorManager`. Lifetime stays bounded —
/// once the session completes (or the user cancels), TrezorSession's
/// own teardown disconnects BLE and stops the bridge.
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

    enum Phase: Equatable {
        case waitingForBridge      // BLE connect / THP / pairing — driven by TrezorManager state
        case syncingKeyImages
        case awaitingDeviceConfirm  // signing — Trezor screen showing tx
        case broadcasting
        case complete(message: String)
        case failed(message: String)
    }

    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    let intent: Intent

    /// Direct subscription to the long-lived TrezorManager that lives on
    /// WalletManager. A computed `var` here would silently miss every
    /// state change — `@EnvironmentObject` only republishes for the
    /// outer object, not nested @Published members. Same gotcha that
    /// bit PairTrezorView; passing the manager in via init + observing
    /// it explicitly is the fix.
    @ObservedObject var trezorManager: TrezorManager

    @State private var phase: Phase = .waitingForBridge
    @State private var pairingCodeInput: String = ""
    @State private var sessionTask: Task<Void, Never>? = nil
    @State private var hasStartedSession = false

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
            .interactiveDismissDisabled(isInProgress)
            .onAppear { startBleIfNeeded() }
            .onChange(of: trezorManager.state) { _, _ in
                evaluateBleState()
            }
            .onDisappear {
                sessionTask?.cancel()
                sessionTask = nil
            }
        }
    }

    private var navTitle: String {
        switch intent {
        case .syncSentTransactions: return "Sync Sent Transactions"
        case .send, .sendAll: return "Sign with Trezor"
        }
    }

    private var isInProgress: Bool {
        if case .complete = phase { return false }
        if case .failed = phase { return false }
        return true
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .waitingForBridge:
            bleBringupContent
        case .syncingKeyImages:
            simpleProgress(title: "Syncing key images…", subtitle: "Confirm prompts on your Trezor as they appear.")
        case .awaitingDeviceConfirm:
            simpleProgress(title: "Confirm on your Trezor", subtitle: "Review the transaction details on the device screen.")
        case .broadcasting:
            simpleProgress(title: "Broadcasting…", subtitle: "Submitting the signed transaction to the network.")
        case .complete(let message):
            successContent(message: message)
        case .failed(let message):
            failureContent(message: message)
        }
    }

    @ViewBuilder
    private var bleBringupContent: some View {
        VStack(spacing: 16) {
            headerIcon("lock.shield.fill", color: .orange)

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
            Button {
                guard pairingCodeInput.count == 6 else { return }
                trezorManager.submitPairingCode(pairingCodeInput)
            } label: {
                Text("Confirm")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(pairingCodeInput.count == 6 ? Color.orange : Color.gray, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(pairingCodeInput.count != 6)
        }
    }

    private func headerIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 48))
            .foregroundStyle(color)
    }

    private func progressLabel(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func simpleProgress(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4).padding(.bottom, 4)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
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

    // MARK: - Bottom actions

    @ViewBuilder
    private var bottomActions: some View {
        switch phase {
        case .complete:
            Button {
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
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    phase = .waitingForBridge
                    hasStartedSession = false
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

    /// Kick off BLE scanning if we're not already past it. Idempotent —
    /// TrezorManager.startScanning() guards against re-entry past
    /// the scan stage so onAppear after sheet rebuild is safe.
    private func startBleIfNeeded() {
        if case .bridgeRunning = trezorManager.state {
            // Bridge already up from a prior interaction — jump straight
            // into the operation.
            evaluateBleState()
            return
        }
        trezorManager.startScanning()
    }

    /// Watch TrezorManager state. Once `.bridgeRunning`, kick off the
    /// session task that drives the actual operation.
    private func evaluateBleState() {
        guard !hasStartedSession else { return }
        guard case .bridgeRunning = trezorManager.state else { return }
        hasStartedSession = true
        sessionTask = Task { await runSession() }
    }

    private func cancelAndDismiss() {
        sessionTask?.cancel()
        sessionTask = nil
        // Tear down BLE / bridge so the next attempt starts clean.
        trezorManager.disconnect()
        dismiss()
    }

    // MARK: - Session driver

    @MainActor
    private func runSession() async {
        guard let info = walletManager.activeWallet else {
            phase = .failed(message: "No active wallet.")
            return
        }
        guard walletManager.isHardwareWallet else {
            phase = .failed(message: "Active wallet is not hardware-backed.")
            return
        }

        do {
            switch intent {
            case .syncSentTransactions:
                phase = .syncingKeyImages
                try await runReconnectSync(info: info)
                walletManager.markHardwareSentSyncCompleted()
                phase = .complete(message: "Sent transactions are up to date.")

            case .send(let to, let amount, let memo):
                phase = .syncingKeyImages
                let txId = try await runSend(info: info, to: to, amount: amount, memo: memo, all: false)
                phase = .complete(message: "Transaction broadcast.\n\(shortTx(txId))")

            case .sendAll(let to, let memo):
                phase = .syncingKeyImages
                let txId = try await runSend(info: info, to: to, amount: 0, memo: memo, all: true)
                phase = .complete(message: "Transaction broadcast.\n\(shortTx(txId))")
            }
        } catch is CancellationError {
            phase = .failed(message: "Cancelled.")
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private func shortTx(_ id: String) -> String {
        guard id.count > 16 else { return id }
        return String(id.prefix(8)) + "…" + String(id.suffix(8))
    }

    // MARK: - Operation implementations
    //
    // Both `runReconnectSync` and `runSend` follow the same skeleton —
    // pause primary, open a TREZOR-bound sidecar at the wallet's
    // `deviceWalletId` path, run the wallet2 cold-sign blob exchange,
    // optionally sign+broadcast, tear down. They are kept in this
    // sheet for now (rather than inside `TrezorSession`) so the UI
    // can reflect each phase transition cleanly. A later pass can
    // extract the shared scaffolding back into the actor.

    private func runReconnectSync(info: WalletInfo) async throws {
        try await runWithSidecar(info: info) { _ in
            // Sidecar is alive; key-image sync already happened in the
            // setup helper. Nothing else to do for the sync intent.
        }
    }

    private func runSend(info: WalletInfo, to: String, amount: Decimal, memo: String?, all: Bool) async throws -> String {
        var txId: String = ""
        try await runWithSidecar(info: info) { sidecar in
            await MainActor.run { phase = .awaitingDeviceConfirm }
            if all {
                txId = try await sidecar.sendAll(to: to, memo: memo)
            } else {
                txId = try await sidecar.send(to: to, amount: amount, memo: memo)
            }
            await MainActor.run { phase = .broadcasting }
        }
        return txId
    }

    /// Runs the TREZOR sidecar lifecycle: suspend primary → open sidecar
    /// → blob-exchange key images → invoke caller's body → push key
    /// images back to primary → tear down → unlock primary.
    private func runWithSidecar(info: WalletInfo, _ body: @escaping (MoneroWallet) async throws -> Void) async throws {
        guard let deviceWalletId = info.deviceWalletId else {
            throw NSError(domain: "HardwareSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing sidecar wallet identifier."])
        }
        guard let pin = walletManager.currentPin else {
            throw NSError(domain: "HardwareSession", code: -2, userInfo: [NSLocalizedDescriptionKey: "Wallet is locked."])
        }

        // Capture the primary's outputs before tearing it down.
        let outputsBlob = await walletManager.moneroWallet?.exportOutputsUR()

        // Suspend primary so KitManager has a free slot for the
        // sidecar Kit. `isUnlocked` stays true so the sheet remains
        // presented over WalletView.
        await walletManager.suspendActiveWalletForPairing()

        let sidecar = MoneroWallet()
        do {
            try await sidecar.createFromDevice(
                deviceName: "Trezor",
                walletId: deviceWalletId,
                restoreHeight: info.restoreHeight,
                networkType: walletManager.networkType
            )
        } catch {
            await sidecar.stopAsync()
            try? await walletManager.unlock(pin: pin)
            throw error
        }

        // Wait until wallet2 has populated the address (signals
        // restore_from_device finished talking to the device).
        let deadline = Date().addingTimeInterval(60)
        while sidecar.primaryAddress.isEmpty {
            if Date() >= deadline {
                await sidecar.stopAsync()
                try? await walletManager.unlock(pin: pin)
                throw NSError(domain: "HardwareSession", code: -3, userInfo: [NSLocalizedDescriptionKey: "Trezor didn't respond. Reconnect and try again."])
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        // Hand outputs to sidecar so it generates key images.
        if let outputsBlob {
            _ = await sidecar.importOutputsUR(outputsBlob)
        }
        // Pull key images back so the primary will see spent state.
        let kiBlob = await sidecar.exportKeyImagesUR()

        do {
            try await body(sidecar)
        } catch {
            await sidecar.stopAsync()
            try? await walletManager.unlock(pin: pin)
            throw error
        }

        // Tear down sidecar before re-unlocking primary so the
        // KitManager slot is free in time.
        await sidecar.stopAsync()
        trezorManager.disconnect()

        // Bring primary back online and import the fresh key images.
        try await walletManager.unlock(pin: pin)
        if let kiBlob {
            _ = await walletManager.moneroWallet?.importKeyImagesUR(kiBlob)
        }
    }
}
