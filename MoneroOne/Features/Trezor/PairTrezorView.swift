import SwiftUI
import LocalAuthentication
import MoneroKit

/// Multi-wallet-aware Trezor pairing flow.
///
/// Flow:
///   1. deviceConnect    — BLE scan/connect/THP handshake/pairing code
///                         (driven by TrezorManager state)
///   2. extractingKeys   — open a transient TREZOR-bound wallet2 instance
///                         via MoneroWallet.createFromDevice, read its
///                         primary address + secret view key, stop it.
///                         The on-disk cache stays at <deviceWalletId>
///                         so the future TrezorSession reconnect can
///                         find its sidecar.
///   3. creationDate     — optional restore-height picker
///   4. setPIN           — onboarding only (skipped when isAddingWallet)
///   5. nameWallet       — name + emoji
///   6. creating         — WalletManager.pairTrezorWallet writes a
///                         SOFTWARE/watch_only primary cache + keychain
///                         entry tagged with the .trezor binding.
///   7. done             — dismisses
///
/// If the user cancels after step 2, the orphan sidecar cache lives at
/// `MoneroKit/<deviceWalletId>/...` with no matching WalletInfo entry.
/// `cleanOrphanedDeviceCaches()` (run on app launch) sweeps these up.
struct PairTrezorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6

    /// Injected from `AddWalletView` so the view observes the
    /// long-lived `WalletManager.trezorManager` directly. A computed
    /// `var` here looks tempting but `@EnvironmentObject` only
    /// publishes changes to the outer object — nested @Published
    /// properties on a non-@Published member don't trigger SwiftUI
    /// re-renders. The view would observe scan/connect/handshake
    /// state changes silently and the UI would stay stuck on the
    /// initial state. This is the same pattern the original
    /// trezor-safe7 TrezorScanView used.
    @ObservedObject var trezorManager: TrezorManager

    var isAddingWallet: Bool = false
    var existingPin: String? = nil

    @SceneStorage("pairTrezor.walletName") private var walletName: String = ""
    @SceneStorage("pairTrezor.walletEmoji") private var walletEmoji: String = "\u{1F510}"
    @SceneStorage("pairTrezor.creationDateTS") private var creationDateTS: Double = Date().timeIntervalSince1970
    @SceneStorage("pairTrezor.useCreationDate") private var useCreationDate = true

    @State private var step: Step = .deviceConnect
    @State private var pairingCodeInput: String = ""
    @State private var pairingCodeSubmitted: Bool = false
    @FocusState private var pairingCodeFocused: Bool
    @State private var extractedAddress: String = ""
    @State private var extractedViewKey: String = ""
    @State private var temporaryDeviceWalletId: String = ""
    @State private var deviceModel: String = "Trezor"
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var selectedPINLength = 6
    @FocusState private var focusedField: PINField?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    private enum PINField { case pin, confirmPin }

    private enum Step {
        case deviceConnect      // scan/connect/handshake/pairing — driven by TrezorManager
        case extractingKeys     // calling createFromDevice, polling for address
        case creationDate
        case setPIN
        case nameWallet
        case creating
        case done
    }

    private static let genesisDate: Date = {
        var c = DateComponents(); c.year = 2014; c.month = 4; c.day = 18
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    private var creationDate: Date { Date(timeIntervalSince1970: creationDateTS) }
    private var creationDateBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: creationDateTS) },
            set: { creationDateTS = $0.timeIntervalSince1970 }
        )
    }
    private var canProceedPIN: Bool { pin.count == selectedPINLength && pin == confirmPin }

    var body: some View {
        Group {
            switch step {
            case .deviceConnect:    deviceConnectView
            case .extractingKeys:   extractingKeysView
            case .creationDate:     creationDateView
            case .setPIN:           setPINView
            case .nameWallet:       nameWalletView
            case .creating:         creatingView
            case .done:             EmptyView()
            }
        }
        .navigationTitle("Pair Trezor")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Pair Failed", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onAppear {
            trezorManager.startScanning()
        }
        .onDisappear {
            // Cancel BLE if user dismissed mid-flow. Not relevant once
            // we've extracted keys and torn down the transient wallet.
            if step == .deviceConnect {
                trezorManager.disconnect()
            }
        }
        .onChange(of: trezorManager.state) { _, _ in
            evaluateConnectionState()
        }
    }

    // MARK: - Step 1: device connect (BLE/THP/pairing)

    private var deviceConnectView: some View {
        VStack(spacing: 20) {
            headerView

            switch trezorManager.state {
            case .idle, .scanning:
                scanningContent
            case .connecting:
                progressContent(text: "Connecting…")
            case .connected, .allocatingTHP, .handshaking:
                handshakeContent
            case .pairing:
                // Once the user has submitted a code, pairingCodeRequired
                // flips to false but the state stays `.pairing` while THP
                // verifies. Swap the input UI for a progress indicator so
                // the user sees something is happening.
                if trezorManager.pairingCodeRequired {
                    pairingContent
                } else {
                    progressContent(text: "Verifying pairing code…")
                }
            case .bridgeRunning:
                progressContent(text: "Ready, exporting keys…")
            case .error(let msg):
                errorContent(msg)
            }

            Spacer()
        }
        .padding(.top, 16)
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text(stepTitle)
                .font(.title3.weight(.semibold))
            Text(stepSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var stepTitle: String {
        switch trezorManager.state {
        case .idle, .scanning:                   return "Searching for Trezor"
        case .connecting:                        return "Connecting…"
        case .connected, .allocatingTHP, .handshaking: return "Encrypted Channel"
        case .pairing:                           return "Enter Pairing Code"
        case .bridgeRunning:                     return "Trezor Ready"
        case .error:                             return "Couldn't Connect"
        }
    }

    private var stepSubtitle: String {
        switch trezorManager.state {
        case .idle, .scanning:        return "Unlock your Trezor and turn on Bluetooth."
        case .connecting:             return "Establishing connection over Bluetooth."
        case .connected, .allocatingTHP, .handshaking:
            return "Setting up encrypted communication."
        case .pairing:                return "Type the 6-digit code shown on the Trezor screen."
        case .bridgeRunning:          return "Now exporting your view key from the device."
        case .error:                  return "See the message below and try again."
        }
    }

    private var scanningContent: some View {
        VStack(spacing: 12) {
            if trezorManager.discoveredDevices.isEmpty {
                ProgressView()
                    .padding()
            } else {
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
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
            }
        }
    }

    private func progressContent(text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var handshakeContent: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2).padding()
            if !trezorManager.checklist.isEmpty {
                checklistView
            }
        }
    }

    private var pairingContent: some View {
        VStack(spacing: 16) {
            TextField("000000", text: $pairingCodeInput)
                .keyboardType(.numberPad)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .focused($pairingCodeFocused)
                .onChange(of: pairingCodeInput) { _, newValue in
                    let trimmed = String(newValue.prefix(6))
                    if trimmed != newValue { pairingCodeInput = trimmed }
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

    private var checklistView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(trezorManager.checklist) { item in
                HStack(spacing: 10) {
                    switch item.status {
                    case .pending:    Image(systemName: "circle").foregroundStyle(.secondary)
                    case .inProgress: ProgressView().scaleEffect(0.7)
                    case .success:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.caption.weight(.medium))
                        if let detail = item.detail {
                            Text(detail).font(.caption2).foregroundStyle(item.status == .failed ? .red : .orange)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            Button {
                trezorManager.disconnect()
                trezorManager.startScanning()
            } label: {
                Text("Try Again")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .glassButtonStyle()
            .padding(.horizontal)
        }
    }

    // MARK: - Step 2: extracting keys

    private var extractingKeysView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4).padding()
            Text("Exporting your view key…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Confirm the prompt on your Trezor when it appears.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 32)
    }

    // MARK: - Step 3: creation date

    private var creationDateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 16)
            Text("When was the Trezor wallet created?")
                .font(.headline)
            Text("An accurate date speeds up scanning. Skip to scan from genesis.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Toggle("I know the creation date", isOn: $useCreationDate)
                .padding(.horizontal)

            if useCreationDate {
                DatePicker(
                    "Creation date",
                    selection: creationDateBinding,
                    in: Self.genesisDate...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)
            }

            Button {
                if isAddingWallet, let existingPin {
                    pin = existingPin
                    step = .nameWallet
                } else {
                    step = .setPIN
                }
            } label: {
                Text("Continue")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Step 4: PIN (onboarding only)

    private var setPINView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 16)
            Text("Set a PIN")
                .font(.title3.weight(.semibold))
            Text("Unlocks this wallet on this device. Hardware wallets still need a local PIN so nobody can open the watch view without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            PINEntryFieldView(
                pin: $pin,
                length: selectedPINLength,
                label: "Enter PIN",
                field: PINField.pin,
                focusedField: $focusedField,
                accessibilityID: "pairTrezor.pinEntry",
                onComplete: { focusedField = .confirmPin }
            )
            PINEntryFieldView(
                pin: $confirmPin,
                length: selectedPINLength,
                label: "Confirm PIN",
                field: PINField.confirmPin,
                focusedField: $focusedField,
                accessibilityID: "pairTrezor.confirmPinEntry",
                onComplete: {
                    if canProceedPIN {
                        preferredPINLength = selectedPINLength
                        step = .nameWallet
                    }
                }
            )
            if pin.count == selectedPINLength && confirmPin.count == selectedPINLength && pin != confirmPin {
                Text("PINs don't match")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button {
                preferredPINLength = selectedPINLength
                step = .nameWallet
            } label: {
                Text("Continue")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(canProceedPIN ? Color.orange : Color.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .disabled(!canProceedPIN)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear { focusedField = .pin }
    }

    // MARK: - Step 5: name + emoji

    private var nameWalletView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 16)
            EmojiPickerCircle(emoji: $walletEmoji)
                .padding(.top, 8)
            Text("Tap to pick an emoji")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Wallet name", text: $walletName)
                .textInputAutocapitalization(.sentences)
                .font(.subheadline)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)

            Button {
                pair()
            } label: {
                Text("Pair Trezor")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Step 6: creating

    private var creatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            Text("Pairing wallet…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - State machine

    private func evaluateConnectionState() {
        guard step == .deviceConnect else { return }
        if case .bridgeRunning = trezorManager.state {
            step = .extractingKeys
            Task { await extractKeys() }
        }
    }

    /// Open a transient TREZOR-bound wallet2 instance to read the
    /// device's primary address + view key. The on-disk cache that
    /// wallet2 writes during `restore_from_device` stays put — that's
    /// the sidecar a future `TrezorSession` reconnect will reuse.
    @MainActor
    private func extractKeys() async {
        TrezorLog.log("[Pair] extractKeys: starting")

        // Release the KitManager singleton slot before creating the
        // transient pair-attempt Kit. KitManager allows only one
        // running wallet2 instance; if an existing wallet is already
        // unlocked when the user hits "Connect Trezor", the pair-
        // attempt Kit's `_start()` would loop on a 1s `Thread.sleep`
        // waiting for the slot and the bridge would never see a
        // request from wallet2. After the pair flow finishes,
        // `walletManager.unlock(pin:)` brings up the newly-paired
        // wallet on the freed slot — the previously-active wallet
        // stays as a `WalletInfo` entry the user can switch back to.
        TrezorLog.log("[Pair] extractKeys: suspending active wallet to free KitManager slot")
        await walletManager.suspendActiveWalletForPairing()
        TrezorLog.log("[Pair] extractKeys: active wallet suspended")
        // Use a synthesized device id keyed off the BLE peripheral so
        // the deviceWalletId is stable across pair attempts. After
        // we've extracted the address we recompute it from address +
        // network so the live binding has a stable value tied to the
        // Monero account, not the BLE peripheral.
        let networkSuffix = walletManager.networkType == .testnet ? "_testnet" : ""
        let pairAttemptId = UUID().uuidString
        let tempWalletId = MoneroWallet.stableWalletId(for: "trezor-pair:\(pairAttemptId)\(networkSuffix)")
        temporaryDeviceWalletId = tempWalletId
        TrezorLog.log("[Pair] extractKeys: tempWalletId=%@", tempWalletId)

        let restoreHeight: UInt64 = useCreationDate ? MoneroWallet.restoreHeight(for: creationDate) : 0
        TrezorLog.log("[Pair] extractKeys: restoreHeight=%llu, calling createFromDevice…", restoreHeight)
        let wallet = MoneroWallet()
        do {
            try await wallet.createFromDevice(
                deviceName: "Trezor",
                walletId: tempWalletId,
                restoreHeight: restoreHeight,
                networkType: walletManager.networkType
            )
            TrezorLog.log("[Pair] extractKeys: createFromDevice returned (kit init done, wallet open queued)")
        } catch {
            TrezorLog.log("[Pair] extractKeys: createFromDevice THREW: %@", error.localizedDescription)
            await failPair(error.localizedDescription)
            return
        }

        // Wait for wallet2 to finish restore_from_device so address is
        // populated. wallet2 talks to the device synchronously inside
        // openWallet — typically a few seconds.
        let pollDeadline = Date().addingTimeInterval(45)
        var pollIterations = 0
        while wallet.primaryAddress.isEmpty {
            if Date() >= pollDeadline {
                TrezorLog.log("[Pair] extractKeys: TIMEOUT after %d polls — primaryAddress still empty", pollIterations)
                await wallet.stopAsync()
                await failPair("Trezor didn't respond. Reconnect and try again.")
                return
            }
            if pollIterations % 4 == 0 {
                TrezorLog.log("[Pair] extractKeys: polling (iter=%d, addr=%@)", pollIterations, wallet.primaryAddress.isEmpty ? "empty" : "set")
            }
            pollIterations += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let address = wallet.primaryAddress
        let viewKey = wallet.secretViewKey ?? ""
        TrezorLog.log("[Pair] extractKeys: read address (len=%d), viewKey (len=%d)", address.count, viewKey.count)

        // Stop the runtime instance — its on-disk cache stays. The
        // file-system path `MoneroKit/<tempWalletId>/` will be moved
        // to the real `<deviceWalletId>` location once we know it.
        await wallet.stopAsync()
        TrezorLog.log("[Pair] extractKeys: stopAsync done")

        guard !address.isEmpty, viewKey.count == 64 else {
            await failPair("Couldn't read keys from Trezor.")
            return
        }

        // Fix up state and advance UI.
        extractedAddress = address
        extractedViewKey = viewKey

        // Drop the BLE/THP session — pair-flow doesn't need the device
        // online for the rest of the screens. Reconnect happens
        // separately when the user actually wants to send or sync
        // sent transactions.
        trezorManager.disconnect()

        step = .creationDate
        TrezorLog.log("[Pair] extractKeys: → creationDate")
    }

    private func pair() {
        let trimmedName = walletName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty
            ? WalletStore().nextWalletName(existing: walletManager.wallets)
            : trimmedName
        let restoreDate: Date? = useCreationDate ? creationDate : nil
        // The deviceId in the binding is the THP-derived stable value.
        // For v0 we use the wallet address — it's unique per (device,
        // derivation path) and survives BLE peripheral rotation.
        let deviceId = extractedAddress
        // Last-connected peripheral UUID lets reconnect skip the BLE
        // scan via `retrievePeripherals(withIdentifiers:)`. Apple may
        // rotate the identifier across app launches; treat it as a
        // best-effort hint — `retrievePeripherals` returns empty when
        // it's gone stale and we fall back to a fresh scan.
        let peripheralUUID = trezorManager.bleTransport.lastConnectedPeripheralUUID

        step = .creating
        Task {
            do {
                // Rename the transient pair-attempt cache to the stable
                // deviceWalletId path BEFORE registering the wallet,
                // because `walletManager.unlock(pin:)` opens the wallet
                // at `WalletInfo.deviceWalletId` and the cache must
                // already be there.
                let networkSuffix = walletManager.networkType == .testnet ? "_testnet" : ""
                let stableDeviceWalletId = MoneroWallet.stableWalletId(for: "trezor:\(deviceId)\(networkSuffix)")
                renameSidecarCache(from: temporaryDeviceWalletId, to: stableDeviceWalletId)

                try await walletManager.pairTrezorWallet(
                    name: name,
                    emoji: walletEmoji,
                    address: extractedAddress,
                    viewKey: extractedViewKey,
                    pin: pin,
                    model: deviceModel,
                    deviceId: deviceId,
                    peripheralUUID: peripheralUUID,
                    restoreDate: restoreDate
                )

                if !isAddingWallet {
                    KeychainStorage().savePinLength(selectedPINLength)
                }

                try await walletManager.unlock(pin: pin)

                await MainActor.run {
                    if isAddingWallet {
                        dismiss()
                    } else {
                        step = .done
                    }
                }
            } catch {
                await failPair(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func failPair(_ message: String) {
        errorMessage = message
        showErrorAlert = true
        step = .deviceConnect
    }

    /// Atomically rename the on-disk wallet2 cache directory from
    /// the synthesized pair-attempt id to the stable device-derived
    /// id. Best-effort — failure leaves the cache where it is and
    /// `cleanOrphanedWalletCaches()` will sweep it next launch (since
    /// neither id will match a WalletInfo). The next reconnect would
    /// just rebuild the sidecar from the device, which is correct
    /// but slower.
    private func renameSidecarCache(from oldId: String, to newId: String) {
        guard oldId != newId, !oldId.isEmpty, !newId.isEmpty else { return }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldPath = appSupport.appendingPathComponent("MoneroKit/\(oldId)")
        let newPath = appSupport.appendingPathComponent("MoneroKit/\(newId)")
        guard fm.fileExists(atPath: oldPath.path) else { return }
        if fm.fileExists(atPath: newPath.path) {
            // Newer cache from a previous pair already exists — drop
            // the transient one. Caller's WalletInfo will reuse the
            // existing `<newId>` cache.
            try? fm.removeItem(at: oldPath)
            return
        }
        try? fm.moveItem(at: oldPath, to: newPath)
    }
}
