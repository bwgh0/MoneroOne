import Foundation
import Network

/// Embedded HTTP server that emulates trezord (Trezor Bridge) on localhost:21325.
/// wallet2's libdevice_trezor connects here and the server proxies calls to
/// the Trezor Safe 7 via BLE.
class TrezorBridgeServer {

    private var listener: NWListener?
    private let port: UInt16 = 21325
    private let queue = DispatchQueue(label: "trezor.bridge.server")

    private var transport: TrezorBleTransport
    private var thpChannel: THPChannel?
    private var sessions: [String: Bool] = [:] // sessionId -> active
    private var currentDevicePath: String?
    private var keepaliveTimer: DispatchSourceTimer?

    /// Callback for diagnostic checklist: (requestMsgType, responseMsgType, responsePayload)
    var onCallResult: ((UInt16, UInt16, Data) -> Void)?

    var isRunning: Bool { listener != nil }

    init(transport: TrezorBleTransport, thpChannel: THPChannel? = nil) {
        self.transport = transport
        self.thpChannel = thpChannel
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Only accept localhost connections
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                TrezorLog.log("[Bridge] Server listening on port %d", self?.port ?? 0)
            case .failed(let error):
                TrezorLog.log("[Bridge] Server failed: %@", error.localizedDescription)
                self?.stop()
            default:
                TrezorLog.log("[Bridge] Server state: %@", "\(state)")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            TrezorLog.log("[Bridge] New connection from client")
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)

        // Start BLE keepalive — reads RSSI every 10s to prevent the BLE
        // connection from going stale during idle periods (e.g. the ~48s gap
        // between fee estimation and actual send). This is BLE-level only,
        // NOT a THP message, so it cannot interfere with /call requests.
        startKeepalive()
    }

    func stop() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        listener?.cancel()
        listener = nil
        sessions.removeAll()
        TrezorLog.log("[Bridge] Server stopped")
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.transport.keepConnectionAlive()
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullHTTPRequest(connection, accumulated: Data())
    }

    /// Receive HTTP request data, accumulating until we have the full body
    private func receiveFullHTTPRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var allData = accumulated
            if let data, !data.isEmpty {
                allData.append(data)
            }

            // Check if we have a complete HTTP request
            if let requestString = String(data: allData, encoding: .utf8),
               self.isHTTPRequestComplete(requestString) {
                TrezorLog.log("[Bridge] Complete HTTP request received (%d bytes)", allData.count)
                self.processHTTPRequest(allData, connection: connection)
            } else if isComplete || error != nil {
                // Connection closed or error - process what we have
                if !allData.isEmpty {
                    TrezorLog.log("[Bridge] Connection ended, processing %d bytes", allData.count)
                    self.processHTTPRequest(allData, connection: connection)
                } else {
                    TrezorLog.log("[Bridge] Connection ended with no data")
                    connection.cancel()
                }
            } else {
                // Need more data, keep receiving
                TrezorLog.log("[Bridge] Partial HTTP request (%d bytes), waiting for more", allData.count)
                self.receiveFullHTTPRequest(connection, accumulated: allData)
            }
        }
    }

    /// Check if an HTTP request is complete (headers + body based on Content-Length)
    private func isHTTPRequestComplete(_ request: String) -> Bool {
        // Need at least the header/body separator
        guard let separatorRange = request.range(of: "\r\n\r\n") else {
            return false
        }

        let headerPart = String(request[request.startIndex..<separatorRange.lowerBound])
        let bodyPart = String(request[separatorRange.upperBound...])

        // Check Content-Length header
        let lines = headerPart.components(separatedBy: "\r\n")
        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                let valueStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let contentLength = Int(valueStr) {
                    return bodyPart.utf8.count >= contentLength
                }
            }
        }

        // No Content-Length header means no body expected
        return true
    }

    private func processHTTPRequest(_ data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            TrezorLog.log("[Bridge] ERROR: Could not decode request as UTF-8")
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"invalid request\"}")
            return
        }

        // Parse HTTP request line
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"empty request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            TrezorLog.log("[Bridge] ERROR: Malformed request line: %@", requestLine)
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"malformed request\"}")
            return
        }

        let method = parts[0]
        let path = parts[1]

        // Extract body (everything after the blank line)
        let body: String
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            body = String(requestString[bodyRange.upperBound...])
        } else {
            body = ""
        }

        TrezorLog.log("[Bridge] >>> %@ %@ (body: %d bytes)", method, path, body.utf8.count)

        // Route the request
        routeRequest(method: method, path: path, body: body, connection: connection)
    }

    // MARK: - Routing

    private func routeRequest(method: String, path: String, body: String, connection: NWConnection) {
        // POST / - Version check
        if path == "/" {
            let response = "{\"version\":\"3.0.0\"}"
            TrezorLog.log("[Bridge] <<< / → %@", response)
            sendHTTPResponse(connection, body: response)
            return
        }

        // POST /enumerate - List connected devices
        if path == "/enumerate" {
            handleEnumerate(connection: connection)
            return
        }

        // POST /listen - Long-poll for device changes
        if path == "/listen" {
            handleListen(connection: connection)
            return
        }

        // POST /acquire/{path}/{previous} - Claim device
        if path.hasPrefix("/acquire/") {
            handleAcquire(path: path, connection: connection)
            return
        }

        // POST /release/{session} - Release device
        if path.hasPrefix("/release/") {
            handleRelease(path: path, connection: connection)
            return
        }

        // POST /call/{session} - Exchange protobuf message
        if path.hasPrefix("/call/") {
            handleCall(path: path, body: body, connection: connection)
            return
        }

        TrezorLog.log("[Bridge] <<< 404 for path: %@", path)
        sendHTTPResponse(connection, statusCode: 404, body: "{\"error\":\"not found\"}")
    }

    // MARK: - Endpoint Handlers

    private func handleEnumerate(connection: NWConnection) {
        if case .connected = transport.connectionState {
            let devicePath = currentDevicePath ?? "Trezor-ble-1"
            currentDevicePath = devicePath

            // Find active session for this device
            let activeSession = sessions.first(where: { $0.value })?.key

            let sessionJSON: String
            if let session = activeSession {
                sessionJSON = "\"\(session)\""
            } else {
                sessionJSON = "null"
            }

            let json = "[{\"path\":\"\(devicePath)\",\"vendor\":4617,\"product\":21441,\"session\":\(sessionJSON),\"debug\":false,\"debugSession\":null}]"
            TrezorLog.log("[Bridge] <<< /enumerate → %@", json)
            sendHTTPResponse(connection, body: json)
        } else {
            TrezorLog.log("[Bridge] <<< /enumerate → [] (BLE state: %@)", "\(transport.connectionState)")
            sendHTTPResponse(connection, body: "[]")
        }
    }

    private func handleListen(connection: NWConnection) {
        // Simple implementation: return current state immediately
        TrezorLog.log("[Bridge] /listen → delegating to /enumerate")
        handleEnumerate(connection: connection)
    }

    private func handleAcquire(path: String, connection: NWConnection) {
        // Path format: /acquire/{device_path}/{previous_session}
        let sessionId = UUID().uuidString.lowercased()
        sessions[sessionId] = true
        let response = "{\"session\":\"\(sessionId)\"}"
        TrezorLog.log("[Bridge] <<< /acquire → %@", response)
        sendHTTPResponse(connection, body: response)
    }

    private func handleRelease(path: String, connection: NWConnection) {
        // Path format: /release/{session}
        let components = path.components(separatedBy: "/")
        if components.count >= 3 {
            let sessionId = components[2]
            sessions.removeValue(forKey: sessionId)
            TrezorLog.log("[Bridge] <<< /release session: %@", sessionId)
        }
        sendHTTPResponse(connection, body: "{}")
    }

    private func handleCall(path: String, body: String, connection: NWConnection) {
        // Path format: /call/{session}
        // Body: hex string = [2 bytes msg_type][4 bytes length][protobuf data]
        let hexBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        TrezorLog.log("[Bridge] /call hex body length: %d chars", hexBody.count)
        if hexBody.count < 20 {
            TrezorLog.log("[Bridge] /call hex body: %@", hexBody)
        } else {
            TrezorLog.log("[Bridge] /call hex body (first 20): %@...", String(hexBody.prefix(20)))
        }

        guard hexBody.count >= 12 else { // minimum: 4 (type) + 8 (length)
            TrezorLog.log("[Bridge] ERROR: /call body too short (%d chars)", hexBody.count)
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"body too short\"}")
            return
        }

        guard let messageData = Data(hexString: hexBody) else {
            TrezorLog.log("[Bridge] ERROR: /call invalid hex body")
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"invalid hex\"}")
            return
        }

        // Parse: first 2 bytes = message type, next 4 bytes = length, rest = payload
        guard messageData.count >= 6 else {
            TrezorLog.log("[Bridge] ERROR: /call data too short (%d bytes)", messageData.count)
            sendHTTPResponse(connection, statusCode: 400, body: "{\"error\":\"data too short\"}")
            return
        }

        let msgType = UInt16(messageData[0]) << 8 | UInt16(messageData[1])
        let declaredLen = UInt32(messageData[2]) << 24 | UInt32(messageData[3]) << 16 | UInt32(messageData[4]) << 8 | UInt32(messageData[5])
        let payload = messageData.count > 6 ? messageData.subdata(in: 6..<messageData.count) : Data()

        TrezorLog.log("[Bridge] /call: msgType=%d, declaredLen=%d, actualPayloadLen=%d", msgType, declaredLen, payload.count)

        // Exchange with device via BLE (async) — use THP channel if available
        Task {
            do {
                let respType: UInt16
                let respData: Data

                if let thp = self.thpChannel, thp.state == .encrypted {
                    // Always return cached Features for Initialize(0).
                    // Sending GetFeatures to the Trezor during an active signing
                    // session causes the THP session to hang (the firmware's strict
                    // message whitelist rejects it silently in THP mode).
                    if msgType == 0, let cached = thp.cachedFeatures {
                        TrezorLog.log("[Bridge] /call: returning cached Features for Initialize")
                        (respType, respData) = (cached.msgType, cached.payload)
                    } else {
                        // In THP, sessions are already initialized at creation time.
                        // wallet2 always sends Initialize(0) first, but THP sessions
                        // reject it with "Unexpected message". Remap to GetFeatures(55).
                        let effectiveMsgType = (msgType == 0) ? UInt16(55) : msgType
                        if effectiveMsgType != msgType {
                            TrezorLog.log("[Bridge] /call: remapping Initialize(0) → GetFeatures(55) for THP")
                        }
                        TrezorLog.log("[Bridge] /call: sending via THP encrypted channel...")
                        (respType, respData) = try await thp.sendProtobuf(messageType: effectiveMsgType, data: payload)

                        // Cache Features response so future Initialize(0) calls
                        // never hit the Trezor (prevents hangs during signing)
                        if msgType == 0 && respType == 17 {
                            thp.cachedFeatures = (msgType: respType, payload: respData)
                            TrezorLog.log("[Bridge] /call: cached Features for future Initialize calls")
                        }
                    }
                } else {
                    TrezorLog.log("[Bridge] /call: sending via legacy wire protocol...")
                    (respType, respData) = try await self.transport.exchange(messageType: msgType, data: payload)
                }

                // Encode response as hex: type(2) + length(4) + payload
                var response = Data()
                response.append(UInt8(respType >> 8))
                response.append(UInt8(respType & 0xFF))
                let len = UInt32(respData.count)
                response.append(UInt8((len >> 24) & 0xFF))
                response.append(UInt8((len >> 16) & 0xFF))
                response.append(UInt8((len >> 8) & 0xFF))
                response.append(UInt8(len & 0xFF))
                response.append(respData)

                let hexResponse = response.hexString
                TrezorLog.log("[Bridge] <<< /call response: msgType=%d, payloadLen=%d, hexLen=%d", respType, respData.count, hexResponse.count)
                self.onCallResult?(msgType, respType, respData)
                self.sendHTTPResponse(connection, body: hexResponse)
            } catch {
                TrezorLog.log("[Bridge] ERROR /call: %@", error.localizedDescription)
                self.sendHTTPResponse(connection, statusCode: 500, body: "{\"error\":\"\(error.localizedDescription)\"}")
            }
        }
    }

    // MARK: - HTTP Response

    private func sendHTTPResponse(_ connection: NWConnection, statusCode: Int = 200, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        // No `Access-Control-Allow-Origin` header — the bridge only
        // serves wallet2 (native client) over loopback, never a web
        // origin. Adding `*` would let any Safari tab POST to the
        // bridge while it's warm and proxy Trezor messages through
        // an unlocked device. Trezord ships a strict origin allow-
        // list for the same reason; the safest match is to send no
        // CORS header at all and let the browser block the request.
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error {
                TrezorLog.log("[Bridge] Send error: %@", error.localizedDescription)
            }
            connection.cancel()
        })
    }
}

// MARK: - Hex Data Extensions

extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
