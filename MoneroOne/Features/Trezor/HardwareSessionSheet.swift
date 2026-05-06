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
    @State private var pairingCodeSubmitted = false
    @FocusState private var pairingCodeFocused: Bool

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
                .focused($pairingCodeFocused)
                .onChange(of: pairingCodeInput) { _, newValue in
                    // Auto-submit the moment the user types the 6th
                    // digit — saves an explicit tap. Guarded by
                    // pairingCodeSubmitted so a stray re-trigger from
                    // SwiftUI rebuild doesn't fire submit twice.
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
            // Pop the keyboard the instant the user lands on this step.
            // Slight delay so SwiftUI's transition completes before
            // the focus change triggers the keyboard animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pairingCodeFocused = true
            }
        }
        .onChange(of: trezorManager.state) { _, newState in
            // Reset the submitted flag if THP throws us back out to
            // .pairing (e.g. wrong code), so the user can retype.
            if case .pairing = newState, !trezorManager.pairingCodeRequired {
                // mid-verification; keep flag
            } else if case .pairing = newState {
                pairingCodeSubmitted = false
            }
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
        guard let _ = walletManager.activeWallet else {
            phase = .failed(message: "No active wallet.")
            return
        }
        guard walletManager.isHardwareWallet else {
            phase = .failed(message: "Active wallet is not hardware-backed.")
            return
        }
        guard let wallet = walletManager.moneroWallet else {
            phase = .failed(message: "Wallet not running.")
            return
        }

        do {
            switch intent {
            case .syncSentTransactions:
                phase = .syncingKeyImages
                // wallet2's cold_key_image_sync iterates the active
                // wallet's transfers, asks the device for key images
                // through the bridge, and internally imports them.
                // No sidecar wallet required — the active wallet IS
                // the TREZOR-bound wallet now.
                let ok = await wallet.coldKeyImageSync()
                if !ok {
                    throw NSError(domain: "HardwareSession", code: -10, userInfo: [NSLocalizedDescriptionKey: "Key image sync failed. Check the device is unlocked and try again."])
                }
                wallet.fetchTransactions()
                walletManager.markHardwareSentSyncCompleted()
                phase = .complete(message: "Sent transactions are up to date.")

            case .send(let to, let amount, let memo):
                phase = .awaitingDeviceConfirm
                let txId = try await wallet.send(to: to, amount: amount, memo: memo)
                phase = .broadcasting
                wallet.fetchTransactions()
                phase = .complete(message: "Transaction broadcast.\n\(shortTx(txId))")

            case .sendAll(let to, let memo):
                phase = .awaitingDeviceConfirm
                let txId = try await wallet.sendAll(to: to, memo: memo)
                phase = .broadcasting
                wallet.fetchTransactions()
                phase = .complete(message: "Transaction broadcast.\n\(shortTx(txId))")
            }
        } catch is CancellationError {
            phase = .failed(message: "Cancelled.")
        } catch {
            phase = .failed(message: error.localizedDescription)
        }

        // Tear down BLE/bridge after every session — the wallet stays
        // open, just no longer talking to the device. Refresh continues
        // via cached view key in the device interface.
        trezorManager.disconnect()
    }

    /// Best-effort wipe of the session sidecar's on-disk cache. The
    /// wallet2 wallet has already been closed (`stopAsync`), so the
    /// directory is just SQLite + wallet2 keys/cache files. No-op on
    /// missing path.
    private func deleteSidecarCache(walletId: String) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let path = appSupport.appendingPathComponent("MoneroKit/\(walletId)")
        try? fm.removeItem(at: path)
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

    /// Runs the TREZOR sidecar lifecycle. Currently unused — the
    /// active wallet is now TREZOR-bound directly, so cold-key-image
    /// sync and send both run on it without a sidecar. Kept as a
    /// reference for if we ever revisit the dual-wallet architecture.
    private func runWithSidecar(info: WalletInfo, _ body: @escaping (MoneroWallet) async throws -> Void) async throws {
        guard let deviceWalletId = info.deviceWalletId else {
            throw NSError(domain: "HardwareSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing sidecar wallet identifier."])
        }
        guard let pin = walletManager.currentPin else {
            throw NSError(domain: "HardwareSession", code: -2, userInfo: [NSLocalizedDescriptionKey: "Wallet is locked."])
        }

        // Capture the primary's outputs before tearing it down. `all:
        // true` because the sidecar is freshly opened from device on
        // every session — it has no record of which outputs were
        // already shared, so we always send the full list.
        TrezorLog.log("[Session] runWithSidecar: exportOutputsUR(all:true) on primary…")
        let outputsBlob = await walletManager.moneroWallet?.exportOutputsUR(all: true)
        TrezorLog.log("[Session] runWithSidecar: outputsBlob length=%d", outputsBlob?.count ?? -1)

        // Suspend primary so KitManager has a free slot for the
        // sidecar Kit. `isUnlocked` stays true so the sheet remains
        // presented over WalletView.
        TrezorLog.log("[Session] runWithSidecar: suspending primary…")
        await walletManager.suspendActiveWalletForPairing()

        // Use a session-specific walletId every time so wallet2 sees
        // a fresh wallet that has never refreshed from a node. The
        // alternative — reusing `<deviceWalletId>` — sets
        // `m_has_ever_refreshed_from_node = true` after the first
        // session and from then on wallet2 throws "Hot wallets cannot
        // import outputs" when we try to push the cold wallet's
        // outputs in. Sessions are short-lived and the cache is
        // disposable, so a per-session walletId costs nothing.
        let networkSuffix = walletManager.networkType == .testnet ? "_testnet" : ""
        let sessionWalletId = MoneroWallet.stableWalletId(for: "trezor-session:\(deviceWalletId):\(UUID().uuidString)\(networkSuffix)")
        TrezorLog.log("[Session] runWithSidecar: creating sidecar (sessionWalletId=%@)…", sessionWalletId)
        let sidecar = MoneroWallet()
        do {
            try await sidecar.createSidecarFromDevice(
                deviceName: "Trezor",
                walletId: sessionWalletId,
                restoreHeight: info.restoreHeight,
                networkType: walletManager.networkType
            )
        } catch {
            TrezorLog.log("[Session] runWithSidecar: createSidecarFromDevice THREW: %@", error.localizedDescription)
            await sidecar.stopAsync()
            try? await walletManager.unlock(pin: pin)
            throw error
        }

        // createSidecarFromDevice already awaited prepareOnly which
        // ran wallet2's restore_from_device synchronously (talked to
        // device, populated address). primaryAddress should be
        // available immediately.
        TrezorLog.log("[Session] runWithSidecar: sidecar primaryAddress len=%d", sidecar.primaryAddress.count)
        guard !sidecar.primaryAddress.isEmpty else {
            TrezorLog.log("[Session] runWithSidecar: sidecar address empty after prepareOnly — aborting")
            await sidecar.stopAsync()
            try? await walletManager.unlock(pin: pin)
            throw NSError(domain: "HardwareSession", code: -3, userInfo: [NSLocalizedDescriptionKey: "Trezor didn't respond. Reconnect and try again."])
        }

        // Hand outputs to sidecar so it generates key images.
        if let outputsBlob {
            let imported = await sidecar.importOutputsUR(outputsBlob)
            TrezorLog.log("[Session] runWithSidecar: sidecar.importOutputsUR → %@", imported ? "ok" : "FAILED")
        } else {
            TrezorLog.log("[Session] runWithSidecar: no outputsBlob to import")
        }

        // Pull key images back so the primary will see spent state.
        // wallet2 generates them via the device on this call, so the
        // bridge must still be alive — that's why we do this BEFORE
        // tearing down the sidecar.
        let kiBlob = await sidecar.exportKeyImagesUR(all: true)
        TrezorLog.log("[Session] runWithSidecar: sidecar.exportKeyImagesUR(all:true) → length=%d", kiBlob?.count ?? -1)

        do {
            try await body(sidecar)
        } catch {
            TrezorLog.log("[Session] runWithSidecar: body THREW: %@", error.localizedDescription)
            await sidecar.stopAsync()
            try? await walletManager.unlock(pin: pin)
            throw error
        }

        // Tear down sidecar before re-unlocking primary so the
        // KitManager slot is free in time. Also delete the session
        // cache from disk — it served its purpose and would otherwise
        // hang around as an orphan that `cleanOrphanedWalletCaches`
        // sweeps on next launch.
        TrezorLog.log("[Session] runWithSidecar: tearing down sidecar")
        await sidecar.stopAsync()
        deleteSidecarCache(walletId: sessionWalletId)
        trezorManager.disconnect()

        // Bring primary back online and import the fresh key images.
        TrezorLog.log("[Session] runWithSidecar: re-unlocking primary…")
        try await walletManager.unlock(pin: pin)
        if let kiBlob, !kiBlob.isEmpty {
            let imported = await walletManager.moneroWallet?.importKeyImagesUR(kiBlob)
            TrezorLog.log("[Session] runWithSidecar: primary.importKeyImagesUR → %@", imported == true ? "ok" : "FAILED")
            // Refresh wallet so the newly-decoded outgoing transactions
            // surface in the transaction list. wallet2's import path
            // updates m_transfers but the app's transaction list is a
            // GRDB mirror updated via delegate callbacks — refreshing
            // forces wallet2 to reprocess and fire those callbacks.
            walletManager.moneroWallet?.fetchTransactions()
            await walletManager.refresh()
        } else {
            TrezorLog.log("[Session] runWithSidecar: no key images to import (blob empty)")
        }
    }
}
