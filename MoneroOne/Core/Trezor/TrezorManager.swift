import Combine
import Foundation

struct TrezorChecklistItem: Identifiable, Equatable {
    let id: String
    let label: String
    var status: Status = .pending
    var detail: String?

    enum Status: Equatable {
        case pending, inProgress, success, failed
    }
}

/// Orchestrates the Trezor Safe 7 integration: BLE transport + Bridge server lifecycle.
/// Acts as the single entry point for the app to interact with Trezor hardware.
@MainActor
class TrezorManager: ObservableObject {

    enum State: Equatable {
        case idle
        case scanning
        case connecting
        case connected(deviceName: String)
        case allocatingTHP(deviceName: String)
        case handshaking(deviceName: String)
        case pairing(deviceName: String)
        case bridgeRunning(deviceName: String)
        case error(String)
    }

    enum SigningProgress: Equatable {
        case preparing        // MoneroTransactionInitRequest (501)
        case processingInputs // SetInputRequest (503) / InputViniRequest (507)
        case processingOutputs // SetOutputRequest (511) — Trezor shows address/amount
        case confirmOnDevice  // ButtonRequest (26) received during signing
        case signing          // SignInputRequest (515)
        case finalizing       // FinalRequest (517)
    }

    @Published var state: State = .idle
    @Published var discoveredDevices: [TrezorDevice] = []
    @Published var devicePrompt: DevicePrompt?
    @Published var checklist: [TrezorChecklistItem] = []
    @Published var signingProgress: SigningProgress?

    /// Set to true when THP pairing requires a code entry from the user
    @Published var pairingCodeRequired = false
    /// The pairing code entered by the user
    @Published var pairingCode = ""

    let bleTransport: TrezorBleTransport
    private var bridgeServer: TrezorBridgeServer?
    private var thpChannel: THPChannel?
    private var cancellables = Set<AnyCancellable>()
    private var pairingContinuation: CheckedContinuation<String, Error>?

    /// Device prompts shown during signing
    enum DevicePrompt: Equatable {
        case confirmOnDevice(action: String)
        case enterPin
        case enterPassphrase
    }

    init() {
        bleTransport = TrezorBleTransport()
        setupBindings()
    }

    private func setupBindings() {
        // Forward BLE state to TrezorManager state
        bleTransport.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (bleState: TrezorBleTransport.ConnectionState) in
                guard let self else { return }
                switch bleState {
                case .disconnected:
                    if case .error = self.state { break } // Don't override errors
                    if case .bridgeRunning = self.state { break } // Don't tear down active bridge
                    self.signingProgress = nil
                    self.state = .idle
                    self.stopBridge()
                case .scanning:
                    TrezorLog.log("[Manager] State → scanning")
                    self.state = .scanning
                case .connecting:
                    TrezorLog.log("[Manager] State → connecting")
                    self.state = .connecting
                case .connected:
                    let name = self.bleTransport.connectedDeviceName ?? "Trezor Safe 7"
                    // Only transition to .connected if we're not already in THP setup
                    switch self.state {
                    case .allocatingTHP, .handshaking, .pairing, .bridgeRunning:
                        break  // Don't interrupt THP setup
                    default:
                        self.state = .connected(deviceName: name)
                        // Auto-start THP + bridge when BLE connects
                        self.startBridge()
                    }
                case .error(let msg):
                    self.state = .error(msg)
                }
            }
            .store(in: &cancellables)

        // Forward discovered devices
        bleTransport.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredDevices)
    }

    // MARK: - Public API

    func startScanning() {
        bleTransport.startScanning()
    }

    func stopScanning() {
        bleTransport.stopScanning()
    }

    func connect(to device: TrezorDevice) {
        bleTransport.connect(to: device)
    }

    func disconnect() {
        stopBridge()
        thpChannel = nil
        pairingCodeRequired = false
        pairingCode = ""
        signingProgress = nil
        devicePrompt = nil
        bleTransport.disconnect()
        state = .idle
    }

    var isReady: Bool {
        if case .bridgeRunning = state { return true }
        return false
    }

    /// Auto-reconnect to a previously-connected Trezor device.
    /// Tries the stored peripheral UUID first for fast reconnection,
    /// falls back to BLE scanning if the direct approach fails.
    func autoReconnect() {
        TrezorLog.log("[Manager] autoReconnect: attempting direct reconnect via stored UUID")

        // If Bluetooth is already powered on, try direct reconnect
        if bleTransport.reconnectToLastDevice() {
            TrezorLog.log("[Manager] autoReconnect: direct reconnect initiated")
            return
        }

        // Fallback: start a full BLE scan
        TrezorLog.log("[Manager] autoReconnect: direct reconnect failed, falling back to BLE scan")
        startScanning()

        // Auto-connect to the first discovered Trezor device
        var autoConnectCancellable: AnyCancellable?
        autoConnectCancellable = bleTransport.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (devices: [TrezorDevice]) in
                guard let self else {
                    autoConnectCancellable?.cancel()
                    return
                }
                if let device = devices.first {
                    TrezorLog.log("[Manager] autoReconnect: found device %@, auto-connecting", device.name)
                    autoConnectCancellable?.cancel()
                    self.connect(to: device)
                }
            }
        autoConnectCancellable?.store(in: &cancellables)
    }

    // MARK: - Pairing Code Submission

    /// Called by the UI when the user enters the 6-digit pairing code from the Trezor screen.
    func submitPairingCode(_ code: String) {
        TrezorLog.log("[Manager] Pairing code submitted (%d chars)", code.count)
        pairingCodeRequired = false
        pairingCode = ""
        if let continuation = pairingContinuation {
            pairingContinuation = nil
            continuation.resume(returning: code)
        }
    }

    /// Cancel the pairing flow
    func cancelPairing() {
        pairingCodeRequired = false
        pairingCode = ""
        if let continuation = pairingContinuation {
            pairingContinuation = nil
            continuation.resume(throwing: THPChannelError.pairingFailed("User cancelled"))
        }
    }

    // MARK: - Checklist

    private func resetChecklist() {
        checklist = [
            TrezorChecklistItem(id: "channel", label: "Channel Allocated"),
            TrezorChecklistItem(id: "handshake", label: "Encrypted Handshake"),
            TrezorChecklistItem(id: "pairing", label: "Device Paired"),
            TrezorChecklistItem(id: "session", label: "Session Created"),
            TrezorChecklistItem(id: "initialize", label: "Initialize → Features"),
            TrezorChecklistItem(id: "getAddress", label: "MoneroGetAddress"),
            TrezorChecklistItem(id: "getWatchKey", label: "MoneroGetWatchKey"),
        ]
    }

    private func updateChecklistItem(_ id: String, status: TrezorChecklistItem.Status, detail: String? = nil) {
        if let idx = checklist.firstIndex(where: { $0.id == id }) {
            checklist[idx].status = status
            checklist[idx].detail = detail
        }
    }

    // MARK: - Bridge Lifecycle

    private func startBridge() {
        guard bridgeServer == nil else { return }

        let deviceName: String
        if case .connected(let name) = state {
            deviceName = name
        } else {
            deviceName = "Trezor"
        }

        // Start THP setup asynchronously, then start the bridge
        Task {
            do {
                // Step 1: Set up THP channel
                state = .allocatingTHP(deviceName: deviceName)

                let hostKey = THPPairing.loadOrCreateHostStaticKey()
                let channel = THPChannel(transport: bleTransport, hostStaticKey: hostKey)

                // Set up pairing callback
                channel.onPairingRequired = { [weak self] in
                    guard let self else { throw THPChannelError.pairingFailed("Manager deallocated") }
                    return try await withCheckedThrowingContinuation { continuation in
                        Task { @MainActor in
                            self.pairingContinuation = continuation
                            self.pairingCodeRequired = true
                            self.state = .pairing(deviceName: deviceName)
                        }
                    }
                }

                // Wire up step-update callback for the checklist
                let stepOrder = ["channel", "handshake", "pairing", "session", "initialize", "getAddress", "getWatchKey"]
                channel.onStepUpdate = { [weak self] stepId, success, errorDetail in
                    Task { @MainActor in
                        self?.updateChecklistItem(stepId,
                            status: success ? .success : .failed,
                            detail: errorDetail)
                        // Advance next step to inProgress on success
                        if success, let idx = stepOrder.firstIndex(of: stepId),
                           idx + 1 < stepOrder.count {
                            let nextStep = stepOrder[idx + 1]
                            // Add hints for steps that need user interaction
                            let hint: String? = (nextStep == "pairing") ? "Enter code shown on Trezor" : nil
                            self?.updateChecklistItem(nextStep, status: .inProgress, detail: hint)
                        }
                    }
                }

                self.thpChannel = channel

                state = .allocatingTHP(deviceName: deviceName)
                resetChecklist()
                updateChecklistItem("channel", status: .inProgress)
                TrezorLog.log("[Manager] Starting THP channel setup...")

                try await channel.setup()

                TrezorLog.log("[Manager] THP channel ready, starting bridge server")

                // Step 2: Start bridge with THP channel
                let server = TrezorBridgeServer(transport: bleTransport, thpChannel: channel)
                server.onCallResult = { [weak self] reqType, respType, respPayload in
                    Task { @MainActor in
                        guard let self else { return }
                        let fail = respType == 3 // Failure
                        let errDetail = fail ? THPProto.extractFailureMessage(respPayload) : nil

                        switch reqType {
                        case 0: // Initialize → expect Features(17)
                            self.updateChecklistItem("initialize",
                                status: fail ? .failed : .success,
                                detail: errDetail)
                            // Only advance getAddress if it's not already done
                            // (wallet2 sends Initialize twice, don't overwrite success)
                            if !fail,
                               let item = self.checklist.first(where: { $0.id == "getAddress" }),
                               item.status != .success {
                                self.updateChecklistItem("getAddress", status: .inProgress)
                            }

                        case 540: // MoneroGetAddress → expect MoneroAddress(541)
                            self.updateChecklistItem("getAddress",
                                status: fail ? .failed : .success,
                                detail: errDetail)
                            if !fail { self.updateChecklistItem("getWatchKey", status: .inProgress) }

                        case 542: // MoneroGetWatchKey → expect MoneroWatchKey(543)
                            // ButtonRequest(26) is intermediate — prompt user to confirm on device
                            if respType == 26 {
                                self.updateChecklistItem("getWatchKey",
                                    status: .inProgress,
                                    detail: "Confirm on your Trezor")
                            } else {
                                self.updateChecklistItem("getWatchKey",
                                    status: fail ? .failed : .success,
                                    detail: errDetail)
                            }

                        case 27: // ButtonAck → carries the final response (e.g. MoneroWatchKey)
                            if respType == 543 { // MoneroWatchKey
                                self.updateChecklistItem("getWatchKey",
                                    status: .success)
                            } else if fail {
                                self.updateChecklistItem("getWatchKey",
                                    status: .failed,
                                    detail: errDetail)
                            }
                            // During signing, ButtonAck clears the device prompt
                            if self.signingProgress != nil {
                                self.devicePrompt = nil
                            }

                        // --- Monero transaction signing (message types 501–518) ---

                        case 501: // MoneroTransactionInitRequest
                            self.signingProgress = .preparing

                        case 503, 507: // MoneroTransactionSetInputRequest / MoneroTransactionInputViniRequest
                            self.signingProgress = .processingInputs

                        case 511: // MoneroTransactionSetOutputRequest
                            self.signingProgress = .processingOutputs

                        case 515: // MoneroTransactionSignInputRequest
                            self.signingProgress = .signing

                        case 517: // MoneroTransactionFinalRequest
                            self.signingProgress = .finalizing

                        default:
                            break
                        }

                        // Response-type checks during signing
                        if self.signingProgress != nil {
                            if respType == 26 { // ButtonRequest — Trezor wants user confirmation
                                self.signingProgress = .confirmOnDevice
                                self.devicePrompt = .confirmOnDevice(action: "Confirm the transaction on your Trezor")
                            } else if respType == 518 { // MoneroTransactionFinalAck — signing complete
                                self.signingProgress = nil
                                self.devicePrompt = nil
                            } else if respType == 3 { // Failure during signing
                                self.signingProgress = nil
                                self.devicePrompt = nil
                            }
                        }
                    }
                }
                try server.start()
                bridgeServer = server

                state = .bridgeRunning(deviceName: deviceName)
                TrezorLog.log("[Manager] Bridge started with THP")
            } catch {
                TrezorLog.log("[Manager] THP/Bridge setup failed: %@", error.localizedDescription)
                state = .error("Setup failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopBridge() {
        bridgeServer?.stop()
        bridgeServer = nil
        thpChannel = nil
        TrezorLog.log("[Manager] Bridge stopped")
    }
}
