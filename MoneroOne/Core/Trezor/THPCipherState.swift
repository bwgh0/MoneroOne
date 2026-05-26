import CryptoKit
import Foundation

/// AES-256-GCM cipher state for THP encrypted transport.
///
/// After the Noise_XX handshake completes, two THPCipherState instances are created:
/// one for sending (host → device) and one for receiving (device → host).
/// Each maintains an auto-incrementing nonce counter.
class THPCipherState {

    private var key: SymmetricKey
    private var nonce: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Initialize from raw key bytes (32 bytes for AES-256)
    convenience init(keyData: Data) {
        self.init(key: SymmetricKey(data: keyData))
    }

    /// Encrypt plaintext with associated data.
    /// Returns ciphertext + 16-byte GCM authentication tag.
    func encrypt(plaintext: Data, aad: Data = Data()) throws -> Data {
        let nonceBytes = makeNonce()
        let aesNonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce, authenticating: aad)

        nonce += 1

        // Return ciphertext + tag (no nonce — receiver tracks its own counter)
        var result = sealed.ciphertext
        result.append(sealed.tag)
        return result
    }

    /// Decrypt ciphertext (with appended 16-byte tag) using associated data.
    func decrypt(ciphertext: Data, aad: Data = Data()) throws -> Data {
        guard ciphertext.count >= 16 else {
            throw THPCryptoError.ciphertextTooShort
        }

        let nonceBytes = makeNonce()
        let aesNonce = try AES.GCM.Nonce(data: nonceBytes)

        let tagStart = ciphertext.count - 16
        let ct = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(16)

        let sealedBox = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: ct, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: aad)

        nonce += 1

        return plaintext
    }

    /// Build 12-byte nonce: 4 bytes zero + 8 bytes big-endian counter
    private func makeNonce() -> Data {
        var nonceData = Data(repeating: 0, count: 4)
        var be = nonce.bigEndian
        nonceData.append(Data(bytes: &be, count: 8))
        return nonceData
    }

    /// Reset nonce counter (used when re-keying)
    func resetNonce() {
        nonce = 0
    }
}

// MARK: - Errors

enum THPCryptoError: LocalizedError {
    case ciphertextTooShort
    case decryptionFailed
    case invalidKeyLength

    var errorDescription: String? {
        switch self {
        case .ciphertextTooShort:
            return "THP ciphertext too short (missing authentication tag)"
        case .decryptionFailed:
            return "THP decryption failed (authentication tag mismatch)"
        case .invalidKeyLength:
            return "THP invalid key length (expected 32 bytes)"
        }
    }
}
