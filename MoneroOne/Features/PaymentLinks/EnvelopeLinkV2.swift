import Foundation
import CryptoKit
import Security

/// Payment link format v2 (2026-10-14): a 16-byte secret in place of the
/// 25 seed words of v1, so the link is about 48 characters long:
///
///     https://monero.one/c#2<secret><height>
///
/// - `2`: the format version, one character.
/// - `<secret>`: 16 random bytes read as one big-endian unsigned integer,
///   written in Base58 (Monero/Bitcoin alphabet), left-padded with `1` to
///   exactly 22 characters.
/// - `<height>`: the restore height as a Base58 integer, 1 to 11 characters.
///
/// Derivation, the same on iOS and Android (labels are UTF-8):
/// - `k = SHA-256("monero.one payment link v2 spend" || secret)`
/// - envelope spend key = `sc_reduce32(k)`; the wallet restores from the 25
///   legacy (Electrum, English) words of that reduced key. `k ≥ l` for about
///   15 of 16 secrets. wallet2 reduces what it restores and hashes the
///   reduced key for the view key, so it would open the same wallet from
///   the words of `k`; a port that derives the keys itself must hash the
///   reduced key too (hashing `k` gives another address, spec vector 2).
/// - envelope id = lowercase hex of the first 8 bytes of
///   `SHA-256("monero.one payment link v2 id" || secret)`.
///
/// The link carries no amount and no expiry: the sender keeps the expiry in
/// its own record, and the recipient learns the amount from the envelope.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Link format v2".
enum EnvelopeV2 {
    static let versionCharacter: Character = "2"
    static let secretByteCount = 16
    static let secretLength = 22
    /// Base58 digits of `UInt64.max`.
    static let maxHeightLength = 11

    static let spendLabel = "monero.one payment link v2 spend"
    static let idLabel = "monero.one payment link v2 id"

    /// 16 random bytes.
    static func newSecret() -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes
    }

    /// `k = SHA-256(spendLabel || secret)`, 32 bytes.
    static func k(secret: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Array(spendLabel.utf8) + secret))
    }

    /// The envelope's secret spend key: `sc_reduce32(k)`.
    static func spendKey(secret: [UInt8]) -> [UInt8] {
        EnvelopeCrypto.reduce(k(secret: secret))
    }

    /// The 25 legacy words the envelope wallet restores from.
    static func words(secret: [UInt8]) -> [String]? {
        let spend = spendKey(secret: secret)
        guard EnvelopeCrypto.isCanonicalNonZero(spend) else { return nil }
        return EnvelopeWords.encode(spend)
    }

    /// Envelope id: first 8 bytes of `SHA-256(idLabel || secret)`, hex.
    static func id(secret: [UInt8]) -> String {
        Array(Array(SHA256.hash(data: Array(idLabel.utf8) + secret)).prefix(8)).hexString
    }

    /// The fragment after `#`: `2<secret><height>`.
    static func fragment(secret: [UInt8], restoreHeight: UInt64) -> String? {
        guard secret.count == secretByteCount,
              let encoded = Base58Integer.encode(bigEndian: secret, width: secretLength) else { return nil }
        return "\(versionCharacter)\(encoded)\(Base58Integer.encode(restoreHeight))"
    }

    /// Reads the part after the version character: 22 secret characters,
    /// then 1 to 11 height characters, every one in the Base58 alphabet.
    /// Nil for a wrong length, a character outside the alphabet or a value
    /// that does not fit (secret ≥ 2^128, height > UInt64.max).
    static func parseBody(_ body: Substring) -> (secret: [UInt8], restoreHeight: UInt64)? {
        guard body.count > secretLength, body.count <= secretLength + maxHeightLength else { return nil }
        let split = body.index(body.startIndex, offsetBy: secretLength)
        guard let secret = Base58Integer.decode(body[..<split], byteCount: secretByteCount),
              let height = Base58Integer.decodeUInt64(body[split...]) else { return nil }
        return (secret, height)
    }
}

/// Unsigned integers in Base58, most significant digit first, with the
/// Monero/Bitcoin alphabet. Not Monero's block Base58 (`MoneroBase58`, for
/// addresses) and not Bitcoin's leading-zero-byte rule: the value is one
/// number, padded with `1` (digit 0) to a fixed width where one is asked.
enum Base58Integer {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let digit: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    /// Shortest form, at least one character ("1" for zero).
    static func encode(_ value: UInt64) -> String {
        var value = value
        var chars: [Character] = []
        repeat {
            chars.append(alphabet[Int(value % 58)])
            value /= 58
        } while value > 0
        return String(chars.reversed())
    }

    static func decodeUInt64(_ text: Substring) -> UInt64? {
        guard !text.isEmpty else { return nil }
        var value: UInt64 = 0
        for ch in text {
            guard let d = digit[ch] else { return nil }
            let (times, o1) = value.multipliedReportingOverflow(by: 58)
            let (sum, o2) = times.addingReportingOverflow(UInt64(d))
            guard !o1, !o2 else { return nil }
            value = sum
        }
        return value
    }

    /// `bytes` as one big-endian integer, left-padded with `1` to `width`.
    /// Nil when the value needs more than `width` digits.
    static func encode(bigEndian bytes: [UInt8], width: Int) -> String? {
        var number = bytes
        var digits: [Int] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices {
                let accumulator = remainder * 256 + Int(number[i])
                number[i] = UInt8(accumulator / 58)
                remainder = accumulator % 58
            }
            digits.append(remainder)
        }
        guard digits.count <= width else { return nil }
        return String(repeating: "1", count: width - digits.count) + String(digits.reversed().map { alphabet[$0] })
    }

    /// The big-endian bytes of `text`, exactly `byteCount` long. Nil for a
    /// character outside the alphabet or a value that does not fit.
    static func decode(_ text: Substring, byteCount: Int) -> [UInt8]? {
        guard !text.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: byteCount)
        for ch in text {
            guard let d = digit[ch] else { return nil }
            var carry = d
            for i in stride(from: byteCount - 1, through: 0, by: -1) {
                let accumulator = Int(out[i]) * 58 + carry
                out[i] = UInt8(accumulator & 0xff)
                carry = accumulator >> 8
            }
            guard carry == 0 else { return nil }
        }
        return out
    }
}
