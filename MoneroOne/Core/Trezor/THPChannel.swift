import CryptoKit
import Foundation
import UIKit

/// THP channel orchestrator.
///
/// Manages the full THP lifecycle:
/// 1. Channel allocation (CID assignment on broadcast channel)
/// 2. Noise_XX handshake (encrypted channel establishment)
/// 3. Pairing (CodeEntry method with CPace)
/// 4. Encrypted protobuf message exchange (what wallet2 uses)
///
/// Uses Alternating Bit Protocol (ABP) for reliable delivery.
class THPChannel {

    enum State: Equatable {
        case idle
        case allocated
        case handshaking
        case pairing
        case encrypted
        case error(String)
    }

    private(set) var state: State = .idle
    private let transport: TrezorBleTransport

    /// Assigned channel ID (0 until allocated)
    private(set) var cid: UInt16 = 0

    /// ABP send sequence bit — toggled on each successful send
    private var sendSeqBit: Bool = false

    /// ABP expected receive sequence bit
    private var recvSeqBit: Bool = false

    /// Noise handshake state
    private var noiseHandshake: THPNoiseHandshake?

    /// Cipher states for encrypted communication (set after handshake)
    private var cipherSend: THPCipherState?
    private var cipherRecv: THPCipherState?

    /// Host static key (persisted for pairing recognition)
    private let hostStaticKey: Curve25519.KeyAgreement.PrivateKey

    /// Device properties prologue (raw protobuf bytes from allocation response)
    private var devicePropertiesPrologue = Data()

    /// Session ID assigned by ThpCreateNewSession — application messages use this (not 0)
    private var sessionId: UInt8 = 0

    /// Cached Features response. The bridge returns this for Initialize calls
    /// instead of hitting the Trezor, which prevents hangs when a signing
    /// session is active (the Trezor rejects unexpected messages during signing).
    var cachedFeatures: (msgType: UInt16, payload: Data)?

    /// Callback for pairing — called when Trezor displays the 6-digit code.
    /// Should present UI for user to enter the code and return it.
    var onPairingRequired: (() async throws -> String)?

    /// Callback for diagnostic checklist: (stepId, success, errorDetail)
    var onStepUpdate: ((String, Bool, String?) -> Void)?

    init(transport: TrezorBleTransport, hostStaticKey: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.transport = transport
        self.hostStaticKey = hostStaticKey ?? Curve25519.KeyAgreement.PrivateKey()
    }

    // MARK: - Channel Allocation

    func allocateChannel() async throws -> UInt16 {
        // Clear any chunks left over from a prior session — without
        // this, a half-finished previous handshake could feed stale
        // data into the new allocation's read buffer and corrupt the
        // CID we extract from the response.
        transport.clearRawChunkBuffer()

        state = .allocated

        var nonce = Data(count: 8)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }

        TrezorLog.log("[THP] allocateChannel: sending CreateNewChannel with nonce=%@",
                      nonce.map { String(format: "%02x", $0) }.joined())

        let chunks = THPFrame.encodeMultiChunk(
            controlByte: THPControlByte.channelAllocReq,
            cid: THPFrame.broadcastCID,
            payload: nonce
        )

        for chunk in chunks {
            try await transport.writeRawChunk(chunk)
        }

        let response = try await readTHPResponse()

        guard response.payload.count >= 10 else {
            throw THPChannelError.allocationFailed("Response too short (\(response.payload.count) bytes)")
        }

        let echoedNonce = response.payload.prefix(8)
        guard echoedNonce == nonce else {
            throw THPChannelError.allocationFailed("Nonce mismatch")
        }

        cid = UInt16(response.payload[8]) << 8 | UInt16(response.payload[9])

        if response.payload.count > 10 {
            devicePropertiesPrologue = response.payload.subdata(in: 10..<response.payload.count)
        }

        TrezorLog.log("[THP] allocateChannel: assigned CID=%04x, prologue=%d bytes",
                      cid, devicePropertiesPrologue.count)

        onStepUpdate?("channel", true, nil)

        return cid
    }

    // MARK: - Noise Handshake

    func performHandshake() async throws {
        guard cid != 0 else { throw THPChannelError.notAllocated }

        state = .handshaking

        let handshake = THPNoiseHandshake(localStatic: hostStaticKey, prologue: devicePropertiesPrologue)
        noiseHandshake = handshake

        TrezorLog.log("[THP] performHandshake: starting Noise_XX on CID=%04x", cid)

        // Message 1: Host → Device (e + unlock byte)
        let msg1 = handshake.writeMessage1(unlock: true)
        try await sendDataFrame(dataType: .handshakeInitReq, payload: msg1)

        // Message 2: Device → Host (e, ee, s, es)
        let resp2 = try await readTHPResponse()
        try handshake.readMessage2(resp2.payload)

        // Message 3: Host → Device (s, se)
        let msg3 = try handshake.writeMessage3()
        try await sendDataFrame(dataType: .handshakeCompReq, payload: msg3)

        // Derive cipher states
        let (sendCipher, recvCipher) = handshake.split()
        cipherSend = sendCipher
        cipherRecv = recvCipher

        // Wait for HandshakeCompResp (dataType=0x03)
        var handshakeCompResp: THPFrame.DecodedFrame?
        for _ in 0..<20 {
            let resp = try await readTHPResponse()
            if resp.controlByte.isDataMessage && resp.controlByte.dataType == THPControlByte.DataType.handshakeCompResp.rawValue {
                handshakeCompResp = resp
                break
            }
            TrezorLog.log("[THP] performHandshake: skipping ctrl=%02x", resp.controlByte.rawValue)
        }

        guard let compResp = handshakeCompResp else {
            throw NoiseError.handshakeFailed("Never received HandshakeCompResp")
        }

        // Decrypt to get trezor_state
        let decryptedState = try recvCipher.decrypt(ciphertext: compResp.payload)
        let trezorState = decryptedState.first ?? 0
        TrezorLog.log("[THP] performHandshake: trezor_state=%d (0=unpaired, 1=paired, 2=autoconnect)", trezorState)

        onStepUpdate?("handshake", true, nil)

        if trezorState == 0 {
            state = .pairing
            TrezorLog.log("[THP] performHandshake: device requires pairing")
            try await handlePairingFlow()
            onStepUpdate?("pairing", true, nil)
        } else {
            onStepUpdate?("pairing", true, "Already paired")
        }

        // Create a proper session before application messages
        try await createSession()
        onStepUpdate?("session", true, nil)

        state = .encrypted
        TrezorLog.log("[THP] performHandshake: encrypted channel established")
    }

    // MARK: - Session Creation

    /// Create a THP session so the firmware upgrades from SeedlessSessionContext
    /// (which rejects Initialize) to a full SessionContext with cache/seed support.
    private func createSession() async throws {
        guard let sendCipher = cipherSend, let recvCipher = cipherRecv else {
            throw THPChannelError.notEncrypted
        }

        TrezorLog.log("[THP] createSession: sending ThpCreateNewSession(1000) with passphrase=''")

        // ThpCreateNewSession (1000) — explicitly set passphrase="" so the firmware
        // creates a NormalSessionContext (not SeedlessSessionContext which rejects Initialize).
        // In protobuf, a present-but-empty field differs from an absent field.
        var sessionPayload = Data()
        sessionPayload.append(THPProto.encodeBytesField(fieldNumber: 1, value: Data())) // passphrase = ""
        try await sendEncrypted(sessionId: 0, messageType: 1000, payload: sessionPayload, cipher: sendCipher)
        let (sid, respType, respPayload) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)

        TrezorLog.log("[THP] createSession: response sid=%d, type=%d, payload=%d bytes, hex=%@",
                      sid, respType, respPayload.count,
                      respPayload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))

        // Accept ThpNewSession(1001) or Success(2)
        guard respType == 1001 || respType == 2 else {
            let errMsg = THPProto.extractFailureMessage(respPayload)
            throw THPChannelError.sessionCreationFailed("Expected ThpNewSession(1001)/Success(2), got \(respType): \(errMsg)")
        }

        // The firmware creates the seeded session using the same session_id that
        // ThpCreateNewSession was received on (verified in core/src/apps/base.py:264).
        // We sent it on session 0, so the seeded session IS session 0.
        if respType == 1001 {
            // ThpNewSession response — extract explicit new_session_id from field 1
            let newSessionId = THPProto.extractVarintField(respPayload, fieldNumber: 1)
            if newSessionId > 0 && newSessionId <= 255 {
                sessionId = UInt8(newSessionId)
            }
            // else keep sessionId = 0 (sent on session 0)
        }
        // For Success(2) response: session was created on the same session_id we sent on.
        // sessionId stays 0, which is correct.

        TrezorLog.log("[THP] createSession: session created, using sessionId=%d", sessionId)
    }

    /// Probe the Trezor with Initialize(0) to find which session ID actually works,
    /// then cache the Features response so the bridge can return it without re-sending.
    private func probeInitialize() async throws {
        guard let sendCipher = cipherSend, let recvCipher = cipherRecv else {
            throw THPChannelError.notEncrypted
        }

        // Try sessionId candidates: current guess first, then the other
        let candidates: [UInt8] = sessionId == 0 ? [0, 1] : [sessionId, 0]

        for sid in candidates {
            TrezorLog.log("[THP] probeInitialize: trying Initialize(0) on session %d", sid)
            try await sendEncrypted(sessionId: sid, messageType: 0, payload: Data(), cipher: sendCipher)
            let (_, respType, respPayload) = try await readEncrypted(cipher: recvCipher)

            if respType == 17 { // Features
                TrezorLog.log("[THP] probeInitialize: got Features on session %d (%d bytes)", sid, respPayload.count)
                sessionId = sid
                cachedFeatures = (msgType: respType, payload: respPayload)
                onStepUpdate?("initialize", true, nil)
                return
            }

            let detail = respType == 3 ? THPProto.extractFailureMessage(respPayload) : "type=\(respType)"
            TrezorLog.log("[THP] probeInitialize: session %d failed — %@", sid, detail)
        }

        // Neither session worked — report failure but don't throw (bridge can still try)
        onStepUpdate?("initialize", false, "Initialize rejected on all sessions")
        TrezorLog.log("[THP] probeInitialize: all sessions failed")
    }

    // MARK: - Encrypted Protobuf Exchange

    /// Send a protobuf message and receive the response over the encrypted channel.
    /// Payload format: [session_id(1)][msg_type(2 BE)][protobuf]
    ///
    /// For multi-chunk messages, encrypts and builds THP chunks once, then retries
    /// if the first attempt times out. The ABP sequence bit is only toggled on
    /// success so the Trezor accepts retransmissions.
    func sendProtobuf(messageType: UInt16, data: Data) async throws -> (UInt16, Data) {
        guard state == .encrypted,
              let sendCipher = cipherSend,
              let recvCipher = cipherRecv else {
            throw THPChannelError.notEncrypted
        }

        TrezorLog.log("[THP] sendProtobuf: msgType=%d, payloadLen=%d, sessionId=%d", messageType, data.count, sessionId)

        // Build plaintext: [session_id(1)][msg_type(2 BE)][protobuf]
        var frame = Data()
        frame.append(sessionId)
        frame.append(UInt8(messageType >> 8))
        frame.append(UInt8(messageType & 0xFF))
        frame.append(data)

        // Encrypt ONCE — cipher nonce auto-increments on encrypt(), cannot re-encrypt
        let encrypted = try sendCipher.encrypt(plaintext: frame)

        // Build THP chunks ONCE — same ciphertext for retransmission (ABP handles dedup)
        let ctrlByte = THPControlByte(dataType: .encrypted, seq: sendSeqBit, ackSeq: recvSeqBit)
        let chunks = THPFrame.encodeMultiChunk(controlByte: ctrlByte.rawValue, cid: cid, payload: encrypted)
        let isMultiChunk = chunks.count > 1

        TrezorLog.log("[THP] sendProtobuf: ctrl=%02x, seq=%d, ackSeq=%d, %d chunk(s)",
                      ctrlByte.rawValue, sendSeqBit ? 1 : 0, recvSeqBit ? 1 : 0, chunks.count)

        // Retry loop: initial attempt + 1 retry (multi-chunk only)
        let maxAttempts = isMultiChunk ? 2 : 1

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                TrezorLog.log("[THP] sendProtobuf: retry %d — clearing stale buffer", attempt)
                transport.clearRawChunkBuffer()
            }

            // Write all chunks — .withResponse writes await ATT confirmation
            // from device before returning, providing implicit flow control.
            for chunk in chunks {
                try await transport.writeRawChunk(chunk)
            }

            do {
                // Read response (60s timeout for user confirmation on Trezor screen)
                let (_, respType, respPayload) = try await readEncrypted(cipher: recvCipher)

                // SUCCESS — toggle seq bit now
                sendSeqBit.toggle()

                TrezorLog.log("[THP] sendProtobuf: response msgType=%d, payloadLen=%d", respType, respPayload.count)

                if respType == 3 { // Failure
                    let detail = THPProto.extractFailureMessage(respPayload)
                    TrezorLog.log("[THP] sendProtobuf: Failure response — %@", detail)
                }

                return (respType, respPayload)
            } catch {
                if attempt < maxAttempts - 1 {
                    TrezorLog.log("[THP] sendProtobuf: attempt %d failed: %@, will retry", attempt, error.localizedDescription)
                    continue
                }
                throw error
            }
        }

        // Unreachable — loop always throws on last attempt failure
        throw THPChannelError.invalidResponse
    }

    // MARK: - Encrypted I/O Helpers

    /// Send an encrypted message with session_id + message_type header.
    private func sendEncrypted(sessionId: UInt8, messageType: UInt16, payload: Data, cipher: THPCipherState) async throws {
        var frame = Data()
        frame.append(sessionId)
        frame.append(UInt8(messageType >> 8))
        frame.append(UInt8(messageType & 0xFF))
        frame.append(payload)

        let encrypted = try cipher.encrypt(plaintext: frame)
        try await sendDataFrame(dataType: .encrypted, payload: encrypted)
    }

    /// Read and decrypt a message, returning (session_id, message_type, protobuf_data).
    private func readEncrypted(cipher: THPCipherState) async throws -> (UInt8, UInt16, Data) {
        let response = try await readTHPResponse()
        let decrypted = try cipher.decrypt(ciphertext: response.payload)

        guard decrypted.count >= 3 else {
            throw THPChannelError.invalidProtobufFrame
        }

        let sid = decrypted[0]
        let msgType = UInt16(decrypted[1]) << 8 | UInt16(decrypted[2])
        let payload = decrypted.count > 3 ? decrypted.subdata(in: 3..<decrypted.count) : Data()

        TrezorLog.log("[THP] readEncrypted: sid=%d, msgType=%d, payload=%d bytes", sid, msgType, payload.count)

        return (sid, msgType, payload)
    }

    /// Read encrypted, automatically handling ButtonRequest (26) by sending ButtonAck (27).
    /// The Trezor sends ButtonRequest when it needs user confirmation on the device screen.
    private func readEncryptedWithButtonHandling(sendCipher: THPCipherState, recvCipher: THPCipherState) async throws -> (UInt8, UInt16, Data) {
        while true {
            let (sid, msgType, payload) = try await readEncrypted(cipher: recvCipher)
            if msgType == 26 { // ButtonRequest
                TrezorLog.log("[THP] readEncrypted: ButtonRequest received, sending ButtonAck and waiting...")
                try await sendEncrypted(sessionId: sid, messageType: 27, payload: Data(), cipher: sendCipher)
                continue
            }
            return (sid, msgType, payload)
        }
    }

    // MARK: - Frame I/O

    private func sendDataFrame(dataType: THPControlByte.DataType, payload: Data) async throws {
        let ctrlByte = THPControlByte(dataType: dataType, seq: sendSeqBit, ackSeq: recvSeqBit)
        let chunks = THPFrame.encodeMultiChunk(controlByte: ctrlByte.rawValue, cid: cid, payload: payload)

        TrezorLog.log("[THP] sendDataFrame: type=%02x, ctrl=%02x, seq=%d, ackSeq=%d, %d chunk(s)",
                      dataType.rawValue, ctrlByte.rawValue,
                      sendSeqBit ? 1 : 0, recvSeqBit ? 1 : 0, chunks.count)

        for chunk in chunks {
            try await transport.writeRawChunk(chunk)
        }

        sendSeqBit.toggle()
    }

    private func sendACK(for frame: THPFrame.DecodedFrame) async throws {
        let ackCtrl = THPControlByte.ack(seqBit: frame.controlByte.seqBit)
        let chunks = THPFrame.encodeMultiChunk(controlByte: ackCtrl.rawValue, cid: frame.cid, payload: Data())

        for chunk in chunks {
            try await transport.writeRawChunk(chunk)
        }
    }

    private func readTHPResponse(timeout: TimeInterval = 60) async throws -> THPFrame.DecodedFrame {
        // Outer loop: retries when a retransmission is detected
        while true {
            var chunks: [Data] = []
            var expectedTotalSize: Int?

            // Inner loop: collect chunks for one complete frame
            while true {
                let chunk = try await transport.readRawChunk(timeout: timeout)

                if chunks.isEmpty {
                    guard chunk.count >= THPFrame.headerSize else {
                        throw THPChannelError.invalidResponse
                    }

                    let ctrlByte = THPControlByte(rawValue: chunk[0])

                    if ctrlByte.isACK {
                        TrezorLog.log("[THP] readTHPResponse: ACK (ctrl=%02x), continuing", ctrlByte.rawValue)
                        continue
                    }

                    let lengthField = Int(UInt16(chunk[3]) << 8 | UInt16(chunk[4]))
                    expectedTotalSize = THPFrame.headerSize + lengthField

                    chunks.append(chunk)

                    if let expected = expectedTotalSize, expected <= chunk.count {
                        break
                    }
                } else {
                    chunks.append(chunk)

                    if let expected = expectedTotalSize {
                        var totalUseful = min(chunks[0].count, expected)
                        for i in 1..<chunks.count {
                            totalUseful += chunks[i].count - THPFrame.continuationHeaderSize
                        }
                        if totalUseful >= expected { break }
                    }
                }
            }

            let assembled = try THPFrame.reassemble(chunks: chunks)
            let decoded = try THPFrame.decode(data: assembled)

            TrezorLog.log("[THP] readTHPResponse: ctrl=%02x, cid=%04x, payload=%d bytes",
                          decoded.controlByte.rawValue, decoded.cid, decoded.payload.count)

            // CID filter — drop frames addressed to a different channel
            // than the one we're operating on. Stale data from a prior
            // failed handshake (e.g. user retried after Noise error)
            // can otherwise leak into the new channel's message stream
            // and get interpreted as a malformed Noise message 2.
            // The broadcast CID (0xffff) used by allocateChannel is OK
            // before our own CID is assigned.
            if cid != 0 && decoded.cid != cid && decoded.cid != THPFrame.broadcastCID {
                TrezorLog.log("[THP] readTHPResponse: dropping stale frame (cid=%04x, expected=%04x)", decoded.cid, cid)
                continue
            }

            if decoded.controlByte.isDataMessage {
                // ABP retransmission detection: if the sequence bit doesn't match
                // what we expect, the device is re-sending its previous frame
                // (our ACK was lost or arrived late). Re-ACK and discard.
                if decoded.controlByte.seqBit != recvSeqBit {
                    TrezorLog.log("[THP] readTHPResponse: retransmission detected (seq=%d, expected=%d), re-ACKing and discarding",
                                  decoded.controlByte.seqBit ? 1 : 0, recvSeqBit ? 1 : 0)
                    try await sendACK(for: decoded)
                    continue // Discard and wait for the actual new response
                }

                recvSeqBit = !decoded.controlByte.seqBit
                try await sendACK(for: decoded)
            }

            return decoded
        }
    }

    // MARK: - Pairing

    /// Full THP pairing flow using CodeEntry method.
    ///
    /// Protocol steps:
    /// 1. Send ThpPairingRequest → receive ThpPairingRequestApproved
    /// 2. Send ThpSelectMethod(CodeEntry) → receive ThpCodeEntryCommitment
    /// 3. Send ThpCodeEntryChallenge → receive ThpCodeEntryCpaceTrezor
    /// 4. User enters 6-digit code from Trezor screen
    /// 5. CPace key exchange + verification
    /// 6. Credential exchange
    /// 7. End pairing
    private func handlePairingFlow() async throws {
        guard let sendCipher = cipherSend,
              let recvCipher = cipherRecv else {
            throw THPChannelError.notEncrypted
        }

        guard let handshakeHash = noiseHandshake?.handshakeHash else {
            throw THPChannelError.pairingFailed("No handshake hash available")
        }

        // Step 1: ThpPairingRequest (1008)
        // Surface the user's device name + app display name to the
        // Trezor screen — Trezor Suite does the same so users see
        // "Connect to Monero One on Joe's iPhone" instead of the
        // generic bundle name. App name is hardcoded to the proper
        // display string ("Monero One") rather than read from
        // Bundle — CFBundleDisplayName resolves to the no-space
        // bundle id ("MoneroOne") in some build configurations and
        // we want the brand spelling regardless.
        let hostName = UIDevice.current.name
        let appName = "Monero One"
        TrezorLog.log("[THP] pairing: sending PairingRequest (host=%@ app=%@)", hostName, appName)
        let pairingReqPayload = THPProto.encodePairingRequest(hostName: hostName, appName: appName)
        try await sendEncrypted(sessionId: 0, messageType: 1008, payload: pairingReqPayload, cipher: sendCipher)

        // Step 2: ThpPairingRequestApproved (1009) — user confirms on Trezor
        // Device sends ButtonRequest(26) while showing confirmation dialog; respond with ButtonAck(27)
        let (_, approvedType, _) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard approvedType == 1009 else {
            throw THPChannelError.pairingFailed("Expected PairingRequestApproved(1009), got \(approvedType)")
        }
        TrezorLog.log("[THP] pairing: PairingRequestApproved received")

        // Step 3: ThpSelectMethod (1010) — CodeEntry = 2
        let selectPayload = THPProto.encodeVarintField(fieldNumber: 1, value: 2)
        try await sendEncrypted(sessionId: 0, messageType: 1010, payload: selectPayload, cipher: sendCipher)

        // Step 4: ThpCodeEntryCommitment (1024) — SHA256(trezor_secret)
        let (_, commitType, commitPayload) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard commitType == 1024 else {
            throw THPChannelError.pairingFailed("Expected CodeEntryCommitment(1024), got \(commitType)")
        }
        let commitment = THPProto.extractBytesField(commitPayload, fieldNumber: 1)
        TrezorLog.log("[THP] pairing: received commitment (%d bytes)", commitment.count)

        // Step 5: ThpCodeEntryChallenge (1025) — 16-byte random challenge
        var challenge = Data(count: 16)
        _ = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let challengePayload = THPProto.encodeBytesField(fieldNumber: 1, value: challenge)
        try await sendEncrypted(sessionId: 0, messageType: 1025, payload: challengePayload, cipher: sendCipher)

        // Step 6: ThpCodeEntryCpaceTrezor (1026) — Trezor's CPace public key
        // At this point the Trezor displays the 6-digit code on screen
        let (_, cpaceType, cpacePayload) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard cpaceType == 1026 else {
            throw THPChannelError.pairingFailed("Expected CodeEntryCpaceTrezor(1026), got \(cpaceType)")
        }
        let trezorCpaceKey = THPProto.extractBytesField(cpacePayload, fieldNumber: 1)
        guard trezorCpaceKey.count == 32 else {
            throw THPChannelError.pairingFailed("Invalid CPace key length: \(trezorCpaceKey.count)")
        }
        TrezorLog.log("[THP] pairing: received Trezor CPace key, code should be on screen")

        // Step 7: Ask user for the 6-digit code
        guard let callback = onPairingRequired else {
            throw THPChannelError.pairingRequired
        }
        let code = try await callback()
        guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
            throw THPChannelError.pairingFailed("Invalid code: must be 6 digits")
        }
        TrezorLog.log("[THP] pairing: user entered code")

        // Step 8: CPace key exchange
        let prs = Data(code.utf8)
        let cpaceResult = try THPCPace.perform(prs: prs, ci: handshakeHash, bPubkey: trezorCpaceKey)
        let tag = Data(SHA256.hash(data: cpaceResult.sharedSecret))

        // Step 9: ThpCodeEntryCpaceHostTag (1027) — host CPace key + tag
        var hostTagPayload = Data()
        hostTagPayload.append(THPProto.encodeBytesField(fieldNumber: 1, value: cpaceResult.aPubkey))
        hostTagPayload.append(THPProto.encodeBytesField(fieldNumber: 2, value: tag))
        try await sendEncrypted(sessionId: 0, messageType: 1027, payload: hostTagPayload, cipher: sendCipher)

        // Step 10: ThpCodeEntrySecret (1028) — Trezor reveals its secret
        let (_, secretType, secretPayload) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard secretType == 1028 else {
            throw THPChannelError.pairingFailed("Expected CodeEntrySecret(1028), got \(secretType)")
        }
        let trezorSecret = THPProto.extractBytesField(secretPayload, fieldNumber: 1)
        TrezorLog.log("[THP] pairing: received trezor secret (%d bytes)", trezorSecret.count)

        // Step 11: Verify commitment — SHA256(secret) must equal commitment
        let computedCommitment = Data(SHA256.hash(data: trezorSecret))
        guard computedCommitment == commitment else {
            throw THPChannelError.pairingFailed("Commitment verification failed")
        }

        // Step 12: Verify code — SHA256(0x02 || handshake_hash || secret || challenge) % 1000000
        var codeInput = Data([0x02]) // ThpPairingMethod.CodeEntry
        codeInput.append(handshakeHash)
        codeInput.append(trezorSecret)
        codeInput.append(challenge)
        let codeHash = Data(SHA256.hash(data: codeInput))
        let computedCode = THPProto.bigIntMod1M(codeHash)
        guard computedCode == code else {
            throw THPChannelError.pairingFailed("Code mismatch: computed \(computedCode)")
        }
        TrezorLog.log("[THP] pairing: code and commitment verified")

        // Step 13: ThpCredentialRequest (1016) — host static public key
        let hostPub = hostStaticKey.publicKey.rawRepresentation
        let credReqPayload = THPProto.encodeBytesField(fieldNumber: 1, value: hostPub)
        try await sendEncrypted(sessionId: 0, messageType: 1016, payload: credReqPayload, cipher: sendCipher)

        // Step 14: ThpCredentialResponse (1017) — credential from device
        let (_, credType, credPayload) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard credType == 1017 else {
            throw THPChannelError.pairingFailed("Expected CredentialResponse(1017), got \(credType)")
        }
        let credential = THPProto.extractBytesField(credPayload, fieldNumber: 2)
        TrezorLog.log("[THP] pairing: received credential (%d bytes)", credential.count)

        // Store credential for future auto-reconnect
        if !credential.isEmpty {
            THPPairing.storeCredential(deviceId: "trezor_\(cid)", credential: credential)
        }

        // Step 15: ThpEndRequest (1018)
        try await sendEncrypted(sessionId: 0, messageType: 1018, payload: Data(), cipher: sendCipher)

        // Step 16: ThpEndResponse (1019)
        let (_, endType, _) = try await readEncryptedWithButtonHandling(sendCipher: sendCipher, recvCipher: recvCipher)
        guard endType == 1019 else {
            throw THPChannelError.pairingFailed("Expected EndResponse(1019), got \(endType)")
        }

        TrezorLog.log("[THP] pairing: completed successfully")
    }

    // MARK: - Full Setup

    func setup() async throws {
        transport.useTHPMode = true

        TrezorLog.log("[THP] setup: starting channel allocation...")
        do {
            let assignedCID = try await allocateChannel()
            TrezorLog.log("[THP] setup: got CID=%04x, starting handshake...", assignedCID)
        } catch {
            onStepUpdate?("channel", false, error.localizedDescription)
            throw error
        }

        do {
            try await performHandshake()
            TrezorLog.log("[THP] setup: complete, channel is encrypted and ready")
        } catch {
            // Determine which step actually failed based on current state
            switch state {
            case .handshaking:
                onStepUpdate?("handshake", false, error.localizedDescription)
            case .pairing:
                onStepUpdate?("pairing", false, error.localizedDescription)
            default:
                onStepUpdate?("session", false, error.localizedDescription)
            }
            throw error
        }
    }
}

// MARK: - Minimal Protobuf Helpers

enum THPProto {

    /// Encode ThpPairingRequest: field 1 (string) host_name, field 2 (string) app_name
    static func encodePairingRequest(hostName: String, appName: String) -> Data {
        var d = Data()
        d.append(encodeBytesField(fieldNumber: 1, value: Data(hostName.utf8)))
        d.append(encodeBytesField(fieldNumber: 2, value: Data(appName.utf8)))
        return d
    }

    /// Encode a length-delimited field (bytes/string): tag + varint_length + data
    static func encodeBytesField(fieldNumber: Int, value: Data) -> Data {
        var d = Data()
        d.append(UInt8((fieldNumber << 3) | 2)) // wire type 2
        d.append(contentsOf: encodeVarint(UInt64(value.count)))
        d.append(value)
        return d
    }

    /// Encode a varint field: tag + varint_value
    static func encodeVarintField(fieldNumber: Int, value: UInt64) -> Data {
        var d = Data()
        d.append(UInt8((fieldNumber << 3) | 0)) // wire type 0
        d.append(contentsOf: encodeVarint(value))
        return d
    }

    /// Encode a protobuf varint
    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var result = [UInt8]()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            result.append(byte)
        } while v != 0
        return result
    }

    /// Decode a Failure protobuf (field 1 = code varint, field 2 = message string).
    static func extractFailureMessage(_ data: Data) -> String {
        let message = extractBytesField(data, fieldNumber: 2)
        let code = extractVarintField(data, fieldNumber: 1)
        return "code=\(code), msg=\(String(data: message, encoding: .utf8) ?? "none")"
    }

    /// Extract a varint field from protobuf data by field number.
    static func extractVarintField(_ data: Data, fieldNumber: Int) -> UInt64 {
        let expectedTag = UInt8((fieldNumber << 3) | 0)
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            offset += 1
            let wireType = tag & 0x07

            if wireType == 0 {
                let (value, consumed) = decodeVarint(data, offset: offset)
                if tag == expectedTag { return value }
                offset += consumed
            } else if wireType == 2 {
                let (length, consumed) = decodeVarint(data, offset: offset)
                offset += consumed + Int(length)
            } else {
                break
            }
        }
        return 0
    }

    /// Extract a bytes field from protobuf data by field number
    static func extractBytesField(_ data: Data, fieldNumber: Int) -> Data {
        let expectedTag = UInt8((fieldNumber << 3) | 2)
        var offset = 0
        while offset < data.count {
            let tag = data[offset]
            offset += 1
            let wireType = tag & 0x07

            if wireType == 2 {
                let (length, consumed) = decodeVarint(data, offset: offset)
                offset += consumed
                let end = min(offset + Int(length), data.count)
                if tag == expectedTag {
                    return data.subdata(in: offset..<end)
                }
                offset = end
            } else if wireType == 0 {
                let (_, consumed) = decodeVarint(data, offset: offset)
                offset += consumed
            } else {
                break
            }
        }
        return Data()
    }

    /// Decode a protobuf varint, returning (value, bytes_consumed)
    static func decodeVarint(_ data: Data, offset: Int) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift = 0
        var consumed = 0
        var i = offset
        while i < data.count {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            consumed += 1
            i += 1
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        return (result, consumed)
    }

    /// Compute big-endian 256-bit integer mod 1,000,000, formatted as 6-digit string.
    static func bigIntMod1M(_ hash: Data) -> String {
        var result: UInt64 = 0
        for byte in hash {
            result = (result * 256 + UInt64(byte)) % 1_000_000
        }
        return String(format: "%06d", result)
    }
}

// MARK: - Errors

enum THPChannelError: LocalizedError {
    case notAllocated
    case notEncrypted
    case allocationFailed(String)
    case invalidResponse
    case invalidProtobufFrame
    case pairingRequired
    case pairingFailed(String)
    case sessionCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAllocated:
            return "THP channel not allocated"
        case .notEncrypted:
            return "THP channel not encrypted (handshake required)"
        case .allocationFailed(let msg):
            return "THP channel allocation failed: \(msg)"
        case .invalidResponse:
            return "Invalid THP response"
        case .invalidProtobufFrame:
            return "Invalid protobuf frame in THP response"
        case .pairingRequired:
            return "Trezor requires pairing but no handler is set"
        case .pairingFailed(let msg):
            return "THP pairing failed: \(msg)"
        case .sessionCreationFailed(let msg):
            return "THP session creation failed: \(msg)"
        }
    }
}
