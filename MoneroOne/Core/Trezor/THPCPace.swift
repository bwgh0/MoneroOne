import CryptoKit
import Foundation

/// CPace255 protocol for THP pairing code verification.
/// Uses X25519 (via CryptoKit) and Elligator2 (via Curve25519Field).
enum THPCPace {

    struct Result {
        let aPubkey: Data       // 32-byte host ephemeral public key
        let sharedSecret: Data  // 32-byte shared secret
    }

    /// Perform CPace255 key exchange.
    ///
    /// - Parameters:
    ///   - prs: Password (6-digit code as ASCII bytes)
    ///   - ci: Channel identifier (Noise handshake hash, 32 bytes)
    ///   - bPubkey: Trezor's CPace public key (32 bytes)
    /// - Returns: Host public key and shared secret
    static func perform(prs: Data, ci: Data, bPubkey: Data) throws -> Result {
        // 1. Derive generator point from password + channel id
        let generator = deriveGenerator(prs: prs, ci: ci)

        // 2. Generate random private key
        var aPrivkey = Data(count: 32)
        _ = aPrivkey.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }

        // 3. a_pubkey = X25519(a_privkey, generator)
        let privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPrivkey)
        let genPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: generator)
        let aPubkeySecret = try privKey.sharedSecretFromKeyAgreement(with: genPubKey)
        let aPubkey = aPubkeySecret.withUnsafeBytes { Data($0) }

        // 4. shared_secret = X25519(a_privkey, b_pubkey)
        let bPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bPubkey)
        let sharedSecret = try privKey.sharedSecretFromKeyAgreement(with: bPubKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        return Result(aPubkey: aPubkey, sharedSecret: sharedSecretData)
    }

    // MARK: - Generator Derivation

    /// Derive CPace generator from password and channel identifier.
    /// generator = Elligator2(SHA512(generator_string)[:32])
    private static func deriveGenerator(prs: Data, ci: Data, sid: Data = Data()) -> Data {
        let genStr = generatorString(prs: prs, ci: ci, sid: sid)
        let hash = Data(SHA512.hash(data: genStr))
        return Curve25519Field.elligator2(Data(hash.prefix(32)))
    }

    /// Build CPace generator string: lv_cat(DSI, PRS, ZPAD, CI, SID)
    private static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let dsi = Data("CPace255".utf8)
        let dsiPrefixed = prependLen(dsi)
        let prsPrefixed = prependLen(prs)
        let hashBlockSize = 128 // SHA-512
        let lenZpad = max(0, hashBlockSize - (dsiPrefixed.count + prsPrefixed.count + 1))
        let zpad = Data(repeating: 0, count: lenZpad)

        var result = Data()
        result.append(dsiPrefixed)
        result.append(prsPrefixed)
        result.append(prependLen(zpad))
        result.append(prependLen(ci))
        result.append(prependLen(sid))
        return result
    }

    /// Prepend single-byte length (LEB128, max 127)
    private static func prependLen(_ data: Data) -> Data {
        var r = Data([UInt8(data.count)])
        r.append(data)
        return r
    }
}
