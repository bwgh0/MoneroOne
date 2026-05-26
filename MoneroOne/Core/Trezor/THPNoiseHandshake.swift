import CryptoKit
import Foundation

/// Noise_XX_25519_AESGCM_SHA256 handshake for THP.
///
/// Implements the XX pattern (mutual authentication):
///   Message 1: Host → Device: `e, payload`     (ephemeral key + unlock byte)
///   Message 2: Device → Host: `e, ee, s, es`   (device ephemeral + encrypted masked static)
///   Message 3: Host → Device: `s, se, payload`  (encrypted host static + credential)
///
/// The Noise prologue is the raw protobuf bytes of ThpDeviceProperties
/// from the channel allocation response.
class THPNoiseHandshake {

    /// Noise protocol name (32 bytes, null-padded)
    static let protocolName = "Noise_XX_25519_AESGCM_SHA256"

    // Noise state variables
    private var h: Data         // handshake hash
    private var ck: Data        // chaining key
    private var tempKey: Data?  // temporary key for encrypt/decrypt during handshake

    // Key pairs
    private let localEphemeral: Curve25519.KeyAgreement.PrivateKey
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private(set) var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private(set) var remoteStatic: Curve25519.KeyAgreement.PublicKey?

    /// Handshake encryption nonce (resets with each new temp key)
    private var handshakeNonce: UInt64 = 0

    /// The handshake hash after completion — used for CPace channel binding.
    var handshakeHash: Data { h }

    /// Initialize with host static key and device properties prologue.
    ///
    /// - Parameters:
    ///   - localStatic: Host's persistent static key (from Keychain)
    ///   - prologue: Raw protobuf bytes of ThpDeviceProperties from channel allocation
    init(localStatic: Curve25519.KeyAgreement.PrivateKey, prologue: Data) {
        self.localStatic = localStatic
        self.localEphemeral = Curve25519.KeyAgreement.PrivateKey()

        // Initialize per Noise spec Section 5.3:
        // protocol_name is 28 bytes, fits in 32, so pad with zeros
        let nameData = Data(Self.protocolName.utf8)
        var padded = nameData
        if nameData.count < 32 {
            padded.append(Data(repeating: 0, count: 32 - nameData.count))
        }

        // h = SHA256(padded_protocol_name || prologue)
        // ck = padded_protocol_name (before prologue is mixed in)
        self.ck = padded
        // MixHash(prologue): h = SHA256(padded_name || prologue)
        var combined = padded
        combined.append(prologue)
        self.h = Data(SHA256.hash(data: combined))
    }

    // MARK: - Handshake Messages

    /// Message 1: Host → Device
    /// Pattern: `-> e, payload`
    /// Sends ephemeral public key (32 bytes) + unlock byte (1 byte) = 33 bytes.
    /// The unlock byte is mixed into the hash as the Noise payload.
    func writeMessage1(unlock: Bool = true) -> Data {
        let ephemeralPub = localEphemeral.publicKey.rawRepresentation

        // e: MixHash(e.public_key)
        mixHash(ephemeralPub)

        // Payload: unlock byte — EncryptAndHash (no key yet, so plaintext)
        let unlockByte = Data([unlock ? 0x01 : 0x00])
        // Before any DH, tempKey is nil, so encryptAndHash just does mixHash
        mixHash(unlockByte)

        TrezorLog.log("[Noise] writeMessage1: ephemeral pub = %@, unlock=%d",
                      ephemeralPub.prefix(8).map { String(format: "%02x", $0) }.joined(),
                      unlock ? 1 : 0)

        // Output: ephemeral_key(32) + unlock_byte(1) = 33 bytes
        var message = ephemeralPub
        message.append(unlockByte)
        return message
    }

    /// Message 2: Device → Host
    /// Pattern: `<- e, ee, s, es`
    /// Reads device's ephemeral key, performs DH, reads encrypted masked static key.
    /// Expected payload: 96 bytes (32 ephemeral + 48 encrypted static + 16 MAC tag)
    func readMessage2(_ data: Data) throws {
        // e: Read remote ephemeral (32 bytes)
        guard data.count >= 32 else {
            throw NoiseError.messageTooShort
        }
        let remoteEphData = data.subdata(in: 0..<32)
        remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphData)
        mixHash(remoteEphData)

        // ee: DH(local_ephemeral, remote_ephemeral)
        guard let remoteEph = remoteEphemeral else {
            throw NoiseError.missingKey
        }
        let sharedEE = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEph)
        mixKey(sharedSecret: sharedEE)

        // s: DecryptAndHash(remote_static_encrypted)
        // Encrypted masked static key = 32 bytes ciphertext + 16 bytes tag = 48 bytes
        guard data.count >= 80 else {
            throw NoiseError.messageTooShort
        }
        let encryptedStatic = data.subdata(in: 32..<80)
        let remoteStaticData = try decryptAndHash(encryptedStatic)
        remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticData)

        // es: DH(local_ephemeral, remote_static)
        guard let remoteSt = remoteStatic else {
            throw NoiseError.missingKey
        }
        let sharedES = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteSt)
        mixKey(sharedSecret: sharedES)

        // Remaining data is the encrypted payload (MAC tag, 16 bytes)
        if data.count > 80 {
            let encryptedPayload = data.subdata(in: 80..<data.count)
            let _ = try decryptAndHash(encryptedPayload)
        }

        TrezorLog.log("[Noise] readMessage2: remote ephemeral = %@, remote static = %@, total=%d bytes",
                      remoteEphData.prefix(8).map { String(format: "%02x", $0) }.joined(),
                      remoteStaticData.prefix(8).map { String(format: "%02x", $0) }.joined(),
                      data.count)
    }

    /// Message 3: Host → Device
    /// Pattern: `-> s, se, payload`
    /// Sends encrypted host static key + encrypted credential payload.
    func writeMessage3(payload: Data? = nil) throws -> Data {
        var message = Data()

        // s: EncryptAndHash(local_static.public_key)
        let localStaticPub = localStatic.publicKey.rawRepresentation
        let encryptedStatic = try encryptAndHash(localStaticPub)
        message.append(encryptedStatic)

        // se: DH(local_static, remote_ephemeral)
        guard let remoteEph = remoteEphemeral else {
            throw NoiseError.missingKey
        }
        let sharedSE = try localStatic.sharedSecretFromKeyAgreement(with: remoteEph)
        mixKey(sharedSecret: sharedSE)

        // Payload: EncryptAndHash(payload)
        // For THP: ThpHandshakeCompletionReqNoisePayload protobuf
        let payloadData = payload ?? Data()
        let encryptedPayload = try encryptAndHash(payloadData)
        message.append(encryptedPayload)

        TrezorLog.log("[Noise] writeMessage3: encrypted static + payload (%d bytes)", message.count)

        return message
    }

    /// Derive send and receive cipher states after handshake completion.
    /// Per Noise spec Section 5.2: Split()
    func split() -> (send: THPCipherState, recv: THPCipherState) {
        // HKDF(ck, zerolen) -> (k1, k2)
        let (k1, k2) = hkdfSplit(chainingKey: ck, inputKeyMaterial: Data())

        TrezorLog.log("[Noise] split: derived send/recv keys (%d bytes each)", k1.count)

        // Initiator (host) uses k1 for sending, k2 for receiving
        let sendCipher = THPCipherState(keyData: k1)
        let recvCipher = THPCipherState(keyData: k2)

        return (send: sendCipher, recv: recvCipher)
    }

    // MARK: - Noise Primitives

    /// MixHash(data): h = SHA256(h || data)
    private func mixHash(_ data: Data) {
        var combined = h
        combined.append(data)
        h = Data(SHA256.hash(data: combined))
    }

    /// MixKey(shared_secret): Updates ck and tempKey via HKDF
    private func mixKey(sharedSecret: SharedSecret) {
        let ikm = sharedSecret.withUnsafeBytes { Data($0) }
        let (newCK, newTempKey) = hkdfSplit(chainingKey: ck, inputKeyMaterial: ikm)
        ck = newCK
        tempKey = newTempKey
        handshakeNonce = 0  // Reset nonce when key changes
    }

    /// EncryptAndHash(plaintext): Encrypt with tempKey, mix ciphertext into h
    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key = tempKey else {
            // Before any DH, tempKey is nil — just mix hash and return plaintext
            mixHash(plaintext)
            return plaintext
        }

        let ciphertext = try aesGcmEncrypt(key: key, nonce: handshakeNonce, plaintext: plaintext, aad: h)
        handshakeNonce += 1
        mixHash(ciphertext)
        return ciphertext
    }

    /// DecryptAndHash(ciphertext): Decrypt with tempKey, mix ciphertext into h
    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key = tempKey else {
            // Before any DH — no encryption, just mix hash
            mixHash(ciphertext)
            return ciphertext
        }

        let plaintext = try aesGcmDecrypt(key: key, nonce: handshakeNonce, ciphertext: ciphertext, aad: h)
        handshakeNonce += 1
        mixHash(ciphertext)
        return plaintext
    }

    // MARK: - Crypto Helpers

    /// HKDF-SHA256 split: derive two 32-byte keys from chaining key + input key material
    private func hkdfSplit(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let prk = hmacSHA256(key: chainingKey, data: inputKeyMaterial)
        let t1 = hmacSHA256(key: prk, data: Data([0x01]))
        var t2Input = t1
        t2Input.append(0x02)
        let t2 = hmacSHA256(key: prk, data: t2Input)
        return (t1, t2)
    }

    /// HMAC-SHA256
    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    /// AES-256-GCM encrypt with explicit nonce
    private func aesGcmEncrypt(key: Data, nonce: UInt64, plaintext: Data, aad: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceData = makeNonce(nonce)
        let aesNonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: aesNonce, authenticating: aad)

        var result = sealed.ciphertext
        result.append(sealed.tag)
        return result
    }

    /// AES-256-GCM decrypt with explicit nonce
    private func aesGcmDecrypt(key: Data, nonce: UInt64, ciphertext: Data, aad: Data) throws -> Data {
        guard ciphertext.count >= 16 else {
            throw NoiseError.decryptionFailed
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonceData = makeNonce(nonce)
        let aesNonce = try AES.GCM.Nonce(data: nonceData)

        let tagStart = ciphertext.count - 16
        let ct = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(16)

        let sealedBox = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
    }

    /// Build 12-byte nonce: 4 bytes zero + 8 bytes big-endian counter
    private func makeNonce(_ counter: UInt64) -> Data {
        var nonceData = Data(repeating: 0, count: 4)
        var be = counter.bigEndian
        nonceData.append(Data(bytes: &be, count: 8))
        return nonceData
    }
}

// MARK: - Errors

enum NoiseError: LocalizedError {
    case messageTooShort
    case missingKey
    case decryptionFailed
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .messageTooShort:
            return "Noise handshake message too short"
        case .missingKey:
            return "Noise handshake missing required key"
        case .decryptionFailed:
            return "Noise handshake decryption failed"
        case .handshakeFailed(let msg):
            return "Noise handshake failed: \(msg)"
        }
    }
}
