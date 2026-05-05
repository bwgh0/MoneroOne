import CoreBluetooth
import Foundation

/// Trezor Safe 7 BLE UUIDs
enum TrezorBleUUID {
    static let service = CBUUID(string: "8c000001-a59b-4d58-a9ad-073df69fa1b1")
    static let rxCharacteristic = CBUUID(string: "8c000002-a59b-4d58-a9ad-073df69fa1b1")  // Host writes to device
    static let txCharacteristic = CBUUID(string: "8c000003-a59b-4d58-a9ad-073df69fa1b1")  // Device notifies host
}

/// Low-level BLE transport for communicating with Trezor Safe 7.
/// Handles connection, chunk-based I/O, and wire protocol framing.
class TrezorBleTransport: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
        case error(String)
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredDevices: [TrezorDevice] = []
    @Published var connectedDeviceName: String?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    /// Dedicated serial queue for all CoreBluetooth operations.
    /// react-native-ble-plx (used by Trezor Suite) does the same —
    /// using the main queue can stall delegate callbacks during idle.
    private let bleQueue = DispatchQueue(label: "trezor.ble.central")

    // Chunk I/O synchronization
    private let responseQueue = DispatchQueue(label: "trezor.ble.response")
    private var pendingResponse: Data?
    private var responseContinuation: CheckedContinuation<Data, Error>?
    private var incomingBuffer = Data()
    private var expectedResponseLength: Int?

    // Raw chunk I/O for THP protocol
    private var rawChunkContinuation: CheckedContinuation<Data, Error>?
    private var rawChunkBuffer: [Data] = []

    // Write completion tracking (.withResponse)
    private var writeContinuation: CheckedContinuation<Void, Error>?

    /// When true, incoming BLE notifications are routed to the raw chunk handler (THP mode)
    /// instead of the old wire protocol parser.
    var useTHPMode = false

    // Wire protocol constants
    static let chunkSize = 244
    private static let magicHeader: [UInt8] = [0x3f, 0x23, 0x23]  // ?##
    private static let magicContinuation: UInt8 = 0x3f              // ?

    /// When true, will auto-start scanning once Bluetooth powers on
    private var pendingScan = false

    /// Limits non-Trezor device log spam during broad scan
    private var discoveryLogCount = 0

    override init() {
        super.init()
        TrezorLog.log("[BLE] TrezorBleTransport init - creating CBCentralManager on dedicated BLE queue")
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    /// Update @Published properties on main queue (required for SwiftUI).
    /// CBCentralManager delegate callbacks now fire on bleQueue, not main.
    private func updateOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async { block() }
    }

    // MARK: - Public API

    func startScanning() {
        TrezorLog.log("[BLE] startScanning called, centralManager.state=%d", centralManager.state.rawValue)

        // Check if already powered on
        if centralManager.state == .poweredOn {
            beginScan()
            return
        }

        // Not ready yet - set pending flag and also schedule a retry
        TrezorLog.log("[BLE] Bluetooth not ready yet (state=%d), will scan when available", centralManager.state.rawValue)
        pendingScan = true
        if connectionState != .connected {
            updateOnMain { self.connectionState = .scanning }
        }

        // Fallback: re-check state after 2 seconds in case the delegate callback was missed
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingScan else { return }
            TrezorLog.log("[BLE] Fallback check: centralManager.state=%d, pendingScan=%d",
                  self.centralManager.state.rawValue, self.pendingScan ? 1 : 0)
            if self.centralManager.state == .poweredOn {
                TrezorLog.log("[BLE] Fallback: Bluetooth is now powered on, starting scan")
                self.beginScan()
            } else {
                TrezorLog.log("[BLE] Fallback: still not powered on, will keep waiting")
                // Try again after another 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.pendingScan else { return }
                    TrezorLog.log("[BLE] Fallback 2: centralManager.state=%d", self.centralManager.state.rawValue)
                    if self.centralManager.state == .poweredOn {
                        self.beginScan()
                    } else {
                        TrezorLog.log("[BLE] Fallback 2: STILL not powered on - Bluetooth may be disabled or permission denied")
                        self.updateOnMain { self.connectionState = .error("Bluetooth unavailable. Check Settings → Bluetooth and app permissions.") }
                    }
                }
            }
        }
    }

    private func beginScan() {
        pendingScan = false
        updateOnMain { self.discoveredDevices = [] }
        discoveryLogCount = 0
        // Don't overwrite .connected state — the bridge may be active
        if connectionState != .connected {
            updateOnMain { self.connectionState = .scanning }
        }

        // Also check for already-paired Trezor peripherals
        let knownPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [TrezorBleUUID.service])
        TrezorLog.log("[BLE] Already-connected peripherals with Trezor service: %d", knownPeripherals.count)
        for peripheral in knownPeripherals {
            TrezorLog.log("[BLE] Known peripheral: %@ (%@)", peripheral.name ?? "(nil)", peripheral.identifier.uuidString)
            let device = TrezorDevice(id: peripheral.identifier, name: peripheral.name ?? "Trezor", peripheral: peripheral)
            if !discoveredDevices.contains(where: { $0.id == device.id }) {
                updateOnMain { self.discoveredDevices.append(device) }
            }
        }

        // Broad scan (no UUID filter) to catch all nearby BLE devices.
        // The Trezor puts its service UUID in scan response data, not primary advertisement.
        TrezorLog.log("[BLE] Starting BLE scan (broad, no UUID filter)...")
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Stop scanning after 60 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.connectionState == .scanning else { return }
            TrezorLog.log("[BLE] Scan timeout (60s) - found %d other devices, no Trezor", self.discoveryLogCount)
            self.stopScanning()
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            updateOnMain { self.connectionState = .disconnected }
        }
    }

    func connect(to device: TrezorDevice) {
        stopScanning()
        updateOnMain { self.connectionState = .connecting }
        connectedPeripheral = device.peripheral
        device.peripheral.delegate = self
        // Persist peripheral UUID for reconnection after app relaunch
        UserDefaults.standard.set(device.peripheral.identifier.uuidString, forKey: "lastTrezorPeripheralUUID")
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    /// Attempt to reconnect to the last-known Trezor peripheral by stored UUID.
    /// Uses `retrievePeripherals(withIdentifiers:)` for a fast, targeted reconnection
    /// without needing a full BLE scan.
    /// - Returns: `true` if a known peripheral was found and connection was initiated
    @discardableResult
    func reconnectToLastDevice() -> Bool {
        guard centralManager.state == .poweredOn else {
            TrezorLog.log("[BLE] reconnectToLastDevice: Bluetooth not powered on (state=%d)", centralManager.state.rawValue)
            return false
        }

        guard let uuidString = UserDefaults.standard.string(forKey: "lastTrezorPeripheralUUID"),
              let uuid = UUID(uuidString: uuidString) else {
            TrezorLog.log("[BLE] reconnectToLastDevice: no stored peripheral UUID")
            return false
        }

        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals.first else {
            TrezorLog.log("[BLE] reconnectToLastDevice: peripheral %@ not found by system", uuidString)
            return false
        }

        TrezorLog.log("[BLE] reconnectToLastDevice: found peripheral %@ (%@), connecting...", peripheral.name ?? "(nil)", uuidString)
        updateOnMain { self.connectionState = .connecting }
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        return true
    }

    /// Send a raw protobuf message to Trezor and wait for response.
    /// - Parameters:
    ///   - messageType: The protobuf message type ID (uint16)
    ///   - data: The serialized protobuf payload
    /// - Returns: Tuple of (response message type, response protobuf data)
    func exchange(messageType: UInt16, data: Data) async throws -> (UInt16, Data) {
        // Check actual peripheral and characteristic availability, not connectionState
        // (connectionState can be temporarily set to .scanning by UI navigation)
        guard let rx = rxCharacteristic,
              let peripheral = connectedPeripheral,
              peripheral.state == .connected else {
            TrezorLog.log("[BLE] exchange: NOT CONNECTED (state=%@, rx=%@, peripheral=%@, peripheralState=%@)",
                  "\(connectionState)",
                  rxCharacteristic == nil ? "nil" : "ok",
                  connectedPeripheral == nil ? "nil" : "ok",
                  connectedPeripheral.map { "\($0.state.rawValue)" } ?? "n/a")
            throw TrezorError.notConnected
        }

        TrezorLog.log("[BLE] exchange: msgType=%d, payloadLen=%d", messageType, data.count)

        // Frame the message into chunks
        let chunks = frameMessage(messageType: messageType, payload: data)
        TrezorLog.log("[BLE] exchange: framed into %d chunk(s) of %d bytes", chunks.count, Self.chunkSize)

        // Clear any stale response data
        responseQueue.sync {
            incomingBuffer = Data()
            expectedResponseLength = nil
            pendingResponse = nil
        }

        // Write all chunks
        for (i, chunk) in chunks.enumerated() {
            TrezorLog.log("[BLE] exchange: writing chunk %d/%d (%d bytes) hex=%@", i + 1, chunks.count, chunk.count,
                  chunk.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))
            peripheral.writeValue(chunk, for: rx, type: .withoutResponse)
        }

        TrezorLog.log("[BLE] exchange: all chunks written, waiting for response...")

        // Wait for complete response with timeout
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.responseQueue.sync {
                        if let response = self.pendingResponse {
                            self.pendingResponse = nil
                            continuation.resume(returning: response)
                        } else {
                            self.responseContinuation = continuation
                        }
                    }
                }
            }

            // Timeout after 60 seconds
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw TrezorError.deviceError("Response timeout (60s)")
            }

            let result = try await group.next()!
            group.cancelAll()

            // Clean up any pending continuation on timeout
            self.responseQueue.sync {
                self.responseContinuation = nil
            }

            return result
        }

        // Parse response: first 2 bytes = type, next 4 bytes = length, rest = payload
        guard responseData.count >= 6 else {
            TrezorLog.log("[BLE] exchange: response too short (%d bytes)", responseData.count)
            throw TrezorError.invalidResponse
        }

        let respType = UInt16(responseData[0]) << 8 | UInt16(responseData[1])
        // Length is in bytes 2-5 but we already have the full reassembled data
        let respPayload = responseData.subdata(in: 6..<responseData.count)

        TrezorLog.log("[BLE] exchange: response msgType=%d, payloadLen=%d", respType, respPayload.count)
        TrezorLog.log("[BLE] exchange: response hex=%@", responseData.map { String(format: "%02x", $0) }.joined(separator: " "))
        // If it's a Failure (type 3), try to decode the protobuf message string
        if respType == 3, respPayload.count > 2 {
            // Protobuf: field 2 (message) tag = 0x12, then length, then UTF-8 string
            if let msgStr = String(data: respPayload, encoding: .utf8) {
                TrezorLog.log("[BLE] exchange: Failure raw UTF8=%@", msgStr)
            }
            // Try to find the string field (tag 0x12)
            for i in 0..<respPayload.count - 1 {
                if respPayload[i] == 0x12 {
                    let strLen = Int(respPayload[i + 1])
                    let strStart = i + 2
                    if strStart + strLen <= respPayload.count {
                        let strData = respPayload.subdata(in: strStart..<strStart + strLen)
                        if let failMsg = String(data: strData, encoding: .utf8) {
                            TrezorLog.log("[BLE] exchange: Failure message=%@", failMsg)
                        }
                    }
                    break
                }
            }
        }
        return (respType, respPayload)
    }

    // MARK: - Raw Chunk I/O (THP)

    /// Write exactly one BLE chunk (up to 244 bytes) to the device.
    /// Uses .withResponse so CoreBluetooth waits for the Trezor's ATT-level
    /// acknowledgment before returning. This matches how every production
    /// native CoreBluetooth hardware wallet app (Ledger SDK, Blockstream Green)
    /// handles multi-chunk writes — each chunk is confirmed delivered before
    /// the next is sent, providing implicit flow control.
    func writeRawChunk(_ data: Data) async throws {
        guard let rx = rxCharacteristic,
              let peripheral = connectedPeripheral,
              peripheral.state == .connected else {
            throw TrezorError.notConnected
        }

        let chunk: Data
        if data.count < Self.chunkSize {
            var padded = data
            padded.append(Data(repeating: 0, count: Self.chunkSize - data.count))
            chunk = padded
        } else {
            chunk = data.prefix(Self.chunkSize)
        }

        TrezorLog.log("[BLE] writeRawChunk: %d bytes, hex=%@",
                      chunk.count,
                      chunk.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))

        // Write with response — await ATT-level confirmation from device
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.responseQueue.sync {
                        self.writeContinuation = cont
                    }
                    peripheral.writeValue(chunk, for: rx, type: .withResponse)
                }
            }
            group.addTask {
                // 10-second timeout safety net
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw TrezorError.timeout
            }
            // First to complete wins — either write confirmation or timeout
            try await group.next()
            group.cancelAll()
        }

        TrezorLog.log("[BLE] writeRawChunk: write confirmed by device")
    }

    /// Keep the BLE connection alive during idle periods.
    /// Production BLE hardware wallet apps (Ledger SDK, Blockstream Green)
    /// don't use keepalive at all — the BLE link layer maintains the connection.
    /// We keep a minimal RSSI read + notification check as a safety net.
    func keepConnectionAlive() {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected else { return }
        peripheral.readRSSI()

        // Check if TX notifications have silently dropped
        if let tx = txCharacteristic, !tx.isNotifying {
            TrezorLog.log("[BLE] keepConnectionAlive: TX notifications dropped! Re-subscribing...")
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    /// Clear any buffered raw chunks (used before retry attempts to discard stale data).
    func clearRawChunkBuffer() {
        responseQueue.sync {
            rawChunkBuffer.removeAll()
        }
    }

    /// Read exactly one raw BLE chunk from device notifications.
    /// Blocks until a chunk arrives or timeout.
    func readRawChunk(timeout: TimeInterval = 60) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.responseQueue.sync {
                        if let chunk = self.rawChunkBuffer.first {
                            self.rawChunkBuffer.removeFirst()
                            continuation.resume(returning: chunk)
                        } else {
                            self.rawChunkContinuation = continuation
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TrezorError.deviceError("Raw chunk read timeout (\(Int(timeout))s)")
            }

            let result = try await group.next()!
            group.cancelAll()

            self.responseQueue.sync {
                self.rawChunkContinuation = nil
            }

            return result
        }
    }

    /// Process an incoming raw chunk (THP mode).
    /// Called from the BLE notification handler when useTHPMode is true.
    private func processRawChunk(_ data: Data) {
        responseQueue.sync {
            TrezorLog.log("[BLE] processRawChunk: %d bytes, hex=%@",
                          data.count,
                          data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))

            if let continuation = rawChunkContinuation {
                rawChunkContinuation = nil
                continuation.resume(returning: data)
            } else {
                rawChunkBuffer.append(data)
            }
        }
    }

    // MARK: - Wire Protocol

    /// Frame a protobuf message into BLE chunks (244 bytes each)
    private func frameMessage(messageType: UInt16, payload: Data) -> [Data] {
        var chunks: [Data] = []

        // Build the full wire message: magic + type(2) + length(4) + payload
        var header = Data()
        header.append(contentsOf: Self.magicHeader)
        header.append(UInt8(messageType >> 8))
        header.append(UInt8(messageType & 0xFF))
        let len = UInt32(payload.count)
        header.append(UInt8((len >> 24) & 0xFF))
        header.append(UInt8((len >> 16) & 0xFF))
        header.append(UInt8((len >> 8) & 0xFF))
        header.append(UInt8(len & 0xFF))

        var fullMessage = header
        fullMessage.append(payload)

        // Split into chunks
        var offset = 0
        var isFirst = true

        while offset < fullMessage.count {
            var chunk = Data()

            if isFirst {
                // First chunk includes the full header naturally
                let end = min(offset + Self.chunkSize, fullMessage.count)
                chunk = fullMessage.subdata(in: offset..<end)
                isFirst = false
            } else {
                // Continuation chunk: prepend '?' marker
                chunk.append(Self.magicContinuation)
                let end = min(offset + Self.chunkSize - 1, fullMessage.count)
                chunk.append(fullMessage.subdata(in: offset..<end))
            }

            // Pad to chunk size
            if chunk.count < Self.chunkSize {
                chunk.append(Data(repeating: 0, count: Self.chunkSize - chunk.count))
            }

            chunks.append(chunk)
            offset += (isFirst ? Self.chunkSize : Self.chunkSize - 1)
        }

        // Handle edge case: empty payload still needs first chunk padded
        if chunks.isEmpty {
            var chunk = Data()
            chunk.append(contentsOf: Self.magicHeader)
            chunk.append(UInt8(messageType >> 8))
            chunk.append(UInt8(messageType & 0xFF))
            chunk.append(contentsOf: [0, 0, 0, 0]) // length = 0
            chunk.append(Data(repeating: 0, count: Self.chunkSize - chunk.count))
            chunks.append(chunk)
        }

        return chunks
    }

    /// Process incoming BLE chunk from the device
    private func processIncomingChunk(_ data: Data) {
        responseQueue.sync {
            if data.count >= 3,
               data[0] == Self.magicHeader[0],
               data[1] == Self.magicHeader[1],
               data[2] == Self.magicHeader[2] {
                // First chunk of a new response
                // Extract message type (2 bytes) and length (4 bytes) after the 3-byte magic
                guard data.count >= 9 else {
                    TrezorLog.log("[BLE] processChunk: first chunk too short (%d bytes)", data.count)
                    return
                }

                let msgType = UInt16(data[3]) << 8 | UInt16(data[4])
                let msgLen = Int(UInt32(data[5]) << 24 | UInt32(data[6]) << 16 | UInt32(data[7]) << 8 | UInt32(data[8]))
                expectedResponseLength = msgLen + 6 // type(2) + length(4) + payload

                TrezorLog.log("[BLE] processChunk: FIRST chunk - msgType=%d, payloadLen=%d, totalExpected=%d", msgType, msgLen, expectedResponseLength!)

                // Store from after magic (skip ?##, keep type+length+payload)
                incomingBuffer = data.subdata(in: 3..<data.count)
                // Trim padding
                if incomingBuffer.count > expectedResponseLength! {
                    incomingBuffer = incomingBuffer.prefix(expectedResponseLength!)
                }

                TrezorLog.log("[BLE] processChunk: buffer now %d/%d bytes", incomingBuffer.count, expectedResponseLength!)
            } else if data.count >= 1, data[0] == Self.magicContinuation {
                // Continuation chunk
                let payloadData = data.subdata(in: 1..<data.count)
                incomingBuffer.append(payloadData)

                // Trim padding
                if let expected = expectedResponseLength, incomingBuffer.count > expected {
                    incomingBuffer = incomingBuffer.prefix(expected)
                }

                TrezorLog.log("[BLE] processChunk: CONTINUATION chunk - buffer now %d/%d bytes",
                      incomingBuffer.count, expectedResponseLength ?? -1)
            } else {
                TrezorLog.log("[BLE] processChunk: UNKNOWN chunk format - first bytes: %@",
                      data.prefix(min(8, data.count)).map { String(format: "%02x", $0) }.joined(separator: " "))
            }

            // Check if response is complete
            if let expected = expectedResponseLength, incomingBuffer.count >= expected {
                let completeResponse = incomingBuffer.prefix(expected)
                TrezorLog.log("[BLE] processChunk: COMPLETE response (%d bytes)", completeResponse.count)

                if let continuation = responseContinuation {
                    responseContinuation = nil
                    continuation.resume(returning: Data(completeResponse))
                } else {
                    TrezorLog.log("[BLE] processChunk: no continuation waiting, storing as pending")
                    pendingResponse = Data(completeResponse)
                }

                incomingBuffer = Data()
                expectedResponseLength = nil
            }
        }
    }

    private func cleanup() {
        connectedPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        updateOnMain { self.connectionState = .disconnected }
        useTHPMode = false
        responseQueue.sync {
            if let continuation = responseContinuation {
                responseContinuation = nil
                continuation.resume(throwing: TrezorError.disconnected)
            }
            if let rawContinuation = rawChunkContinuation {
                rawChunkContinuation = nil
                rawContinuation.resume(throwing: TrezorError.disconnected)
            }
            if let wCont = writeContinuation {
                writeContinuation = nil
                wCont.resume(throwing: TrezorError.disconnected)
            }
            incomingBuffer = Data()
            expectedResponseLength = nil
            pendingResponse = nil
            rawChunkBuffer.removeAll()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TrezorBleTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        TrezorLog.log("[BLE] centralManagerDidUpdateState: state=%d (0=unknown,1=resetting,2=unsupported,3=unauthorized,4=off,5=on)", central.state.rawValue)
        switch central.state {
        case .poweredOn:
            TrezorLog.log("[BLE] Bluetooth powered on (pendingScan=%d)", pendingScan ? 1 : 0)
            if pendingScan {
                beginScan()
            }
        case .poweredOff:
            TrezorLog.log("[BLE] Bluetooth is powered OFF")
            updateOnMain { self.connectionState = .error("Bluetooth is turned off") }
        case .unauthorized:
            TrezorLog.log("[BLE] Bluetooth UNAUTHORIZED - check app permissions")
            updateOnMain { self.connectionState = .error("Bluetooth permission denied. Go to Settings → MoneroOne → Bluetooth.") }
        case .unsupported:
            TrezorLog.log("[BLE] Bluetooth UNSUPPORTED on this device")
            updateOnMain { self.connectionState = .error("Bluetooth not supported") }
        case .resetting:
            TrezorLog.log("[BLE] Bluetooth is RESETTING")
        case .unknown:
            TrezorLog.log("[BLE] Bluetooth state is UNKNOWN (waiting...)")
        @unknown default:
            TrezorLog.log("[BLE] Bluetooth state is unrecognized: %d", central.state.rawValue)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String

        // Check if this is a Trezor device by service UUID in advertisement or by name
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isTrezorByUUID = serviceUUIDs.contains(TrezorBleUUID.service)
        let isTrezorByName = name?.lowercased().contains("trezor") == true

        // Log first 20 discovered devices for debugging, and always log Trezor matches
        if isTrezorByUUID || isTrezorByName {
            TrezorLog.log("[BLE] *** TREZOR FOUND: name=%@, RSSI=%@, serviceUUIDs=%@, advKeys=%@",
                  name ?? "(nil)", RSSI,
                  serviceUUIDs.map { $0.uuidString }.joined(separator: ","),
                  (advertisementData.keys.map { $0 }).joined(separator: ","))
        } else {
            discoveryLogCount += 1
            if discoveryLogCount <= 20 {
                TrezorLog.log("[BLE] Other device: name=%@, RSSI=%@, services=%@",
                      name ?? "(nil)", RSSI,
                      serviceUUIDs.map { $0.uuidString }.joined(separator: ","))
            } else if discoveryLogCount == 21 {
                TrezorLog.log("[BLE] (suppressing further non-Trezor device logs...)")
            }
        }

        guard isTrezorByUUID || isTrezorByName else { return }

        let displayName = name ?? "Trezor"
        let device = TrezorDevice(id: peripheral.identifier, name: displayName, peripheral: peripheral)

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            updateOnMain { self.discoveredDevices.append(device) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        TrezorLog.log("[BLE] Connected to %@", peripheral.name ?? "unknown")
        updateOnMain { self.connectedDeviceName = peripheral.name ?? "Trezor Safe 7" }
        peripheral.discoverServices([TrezorBleUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        TrezorLog.log("[BLE] Failed to connect: %@", error?.localizedDescription ?? "unknown")
        updateOnMain { self.connectionState = .error("Failed to connect: \(error?.localizedDescription ?? "unknown")") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        TrezorLog.log("[BLE] Disconnected from %@", peripheral.name ?? "unknown")
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension TrezorBleTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            updateOnMain { self.connectionState = .error("Service discovery failed: \(error!.localizedDescription)") }
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == TrezorBleUUID.service }) else {
            updateOnMain { self.connectionState = .error("Trezor BLE service not found") }
            return
        }

        peripheral.discoverCharacteristics([TrezorBleUUID.rxCharacteristic, TrezorBleUUID.txCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            updateOnMain { self.connectionState = .error("Characteristic discovery failed") }
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case TrezorBleUUID.rxCharacteristic:
                rxCharacteristic = characteristic
                let rxProps = characteristic.properties
                TrezorLog.log("[BLE] Found RX characteristic, properties: write=%d writeNoResp=%d read=%d notify=%d",
                              rxProps.contains(.write) ? 1 : 0,
                              rxProps.contains(.writeWithoutResponse) ? 1 : 0,
                              rxProps.contains(.read) ? 1 : 0,
                              rxProps.contains(.notify) ? 1 : 0)
            case TrezorBleUUID.txCharacteristic:
                txCharacteristic = characteristic
                let txProps = characteristic.properties
                TrezorLog.log("[BLE] Found TX characteristic, properties: write=%d writeNoResp=%d read=%d notify=%d",
                              txProps.contains(.write) ? 1 : 0,
                              txProps.contains(.writeWithoutResponse) ? 1 : 0,
                              txProps.contains(.read) ? 1 : 0,
                              txProps.contains(.notify) ? 1 : 0)
                peripheral.setNotifyValue(true, for: characteristic)
                TrezorLog.log("[BLE] Subscribing to TX notifications")
            default:
                break
            }
        }

        if rxCharacteristic != nil && txCharacteristic != nil {
            updateOnMain { self.connectionState = .connected }
            TrezorLog.log("[BLE] Fully connected and ready")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Log ALL callbacks including errors/mismatches for diagnostics
        if let error = error {
            TrezorLog.log("[BLE] didUpdateValue ERROR: %@, uuid=%@", error.localizedDescription, characteristic.uuid.uuidString)
            return
        }
        guard characteristic.uuid == TrezorBleUUID.txCharacteristic,
              let data = characteristic.value else {
            TrezorLog.log("[BLE] didUpdateValue: wrong characteristic or nil data (uuid=%@, data=%d bytes)",
                          characteristic.uuid.uuidString, characteristic.value?.count ?? 0)
            return
        }

        TrezorLog.log("[BLE] Received %d bytes from device", data.count)

        if useTHPMode {
            processRawChunk(data)
        } else {
            processIncomingChunk(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            TrezorLog.log("[BLE] Write error: %@", error.localizedDescription)
        }
        responseQueue.sync {
            if let cont = writeContinuation {
                writeContinuation = nil
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        TrezorLog.log("[BLE] didUpdateNotificationState: uuid=%@, isNotifying=%d, error=%@",
                      characteristic.uuid.uuidString, characteristic.isNotifying ? 1 : 0,
                      error?.localizedDescription ?? "none")
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            TrezorLog.log("[BLE] didReadRSSI: error=%@", error.localizedDescription)
        }
    }
}

// MARK: - Errors

enum TrezorError: LocalizedError {
    case notConnected
    case disconnected
    case invalidResponse
    case timeout
    case bridgeError(String)
    case deviceError(String)
    case bluetoothUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Trezor is not connected"
        case .disconnected: return "Trezor disconnected during operation"
        case .invalidResponse: return "Invalid response from Trezor"
        case .timeout: return "Trezor BLE write timed out"
        case .bridgeError(let msg): return "Bridge error: \(msg)"
        case .deviceError(let msg): return "Device error: \(msg)"
        case .bluetoothUnavailable: return "Bluetooth is not available"
        }
    }
}
