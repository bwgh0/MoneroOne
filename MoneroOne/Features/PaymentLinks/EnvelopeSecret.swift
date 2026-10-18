import Foundation
import Security
import MoneroKit

/// The secret of one envelope: a random 16-byte link secret (link format
/// v2), the 25-word legacy mnemonic it derives, and the address that
/// mnemonic restores to.
///
/// The kit's offline helpers (`Kit.address`, `Kit.key`, `bytesToWords`) are
/// stubs in this library build, so the envelope does the math itself with
/// wallet2's own primitives from the linked Monero library: `sc_reduce32`,
/// `ge_scalarmult_base`, `ge_p3_tobytes` and `cn_fast_hash` (Keccak-256),
/// plus the legacy word codec of `electrum-words.cpp`. Every secret is
/// verified before anyone can fund it: the words decode back to the spend
/// key, and wallet2 (`addressValid`, `keyValid`) confirms that the address
/// is valid and that both secret keys belong to it.
struct EnvelopeSecret: Equatable {
    /// The 16 bytes that go in a v2 link.
    let linkSecret: [UInt8]
    let words: [String]
    let address: String

    enum Failure: LocalizedError {
        case generationFailed
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .generationFailed:
                return String(localized: "Could not make the payment link. Nothing was sent.")
            case .verificationFailed:
                return String(localized: "The payment link failed its safety check. Nothing was sent.")
            }
        }
    }

    /// A new random envelope for a v2 link, verified.
    static func generate(networkType: MoneroKit.NetworkType) throws -> EnvelopeSecret {
        guard let secret = EnvelopeV2.newSecret(),
              let words = EnvelopeV2.words(secret: secret),
              let address = EnvelopeCrypto.address(spendKey: EnvelopeV2.spendKey(secret: secret), networkType: networkType)
        else {
            throw Failure.generationFailed
        }
        try verify(words: words, address: address, networkType: networkType)
        return EnvelopeSecret(linkSecret: secret, words: words, address: address)
    }

    /// Restores `words` and checks that they give `address`: 25 words that
    /// decode with a good checksum, a valid non-null-key address, the same
    /// address back, and view and spend keys that wallet2 accepts for it.
    static func verify(words: [String], address: String, networkType: MoneroKit.NetworkType) throws {
        guard words.count == EnvelopeLink.wordCount,
              !address.isEmpty,
              !NullKeyAddress.isNullKey(address),
              MoneroKit.Kit.isValid(address: address, networkType: networkType),
              let spend = EnvelopeWords.decode(words),
              EnvelopeCrypto.isCanonicalNonZero(spend),
              EnvelopeWords.encode(spend) == words.map({ $0.lowercased() }),
              let restored = EnvelopeCrypto.address(spendKey: spend, networkType: networkType),
              restored == address
        else {
            throw Failure.verificationFailed
        }
        let view = EnvelopeCrypto.viewKey(spendKey: spend)
        guard EnvelopeCrypto.isCanonicalNonZero(view),
              MoneroKit.Kit.isValid(viewKey: view.hexString, address: address, isViewKey: true, networkType: networkType),
              MoneroKit.Kit.isValid(viewKey: spend.hexString, address: address, isViewKey: false, networkType: networkType)
        else {
            throw Failure.verificationFailed
        }
    }

    /// The address `words` restore to, or nil when they do not decode.
    static func address(for words: [String], networkType: MoneroKit.NetworkType) -> String? {
        guard let spend = EnvelopeWords.decode(words), EnvelopeCrypto.isCanonicalNonZero(spend),
              let address = EnvelopeCrypto.address(spendKey: spend, networkType: networkType),
              !NullKeyAddress.isNullKey(address) else { return nil }
        return address
    }

    /// The secret spend key of `words`, hex. Tests and diagnostics only.
    static func spendKeyHex(for words: [String]) -> String? {
        EnvelopeWords.decode(words)?.hexString
    }
}

// MARK: - Legacy word codec

/// wallet2's legacy 25-word mnemonic (`crypto::ElectrumWords`): 32 bytes as
/// eight little-endian 32-bit groups of three words each, then a checksum
/// word picked by CRC-32 over the first 3 letters of every word.
enum EnvelopeWords {
    private static let list = EnvelopeWordlist.english
    private static let n = UInt32(EnvelopeWordlist.english.count)
    private static let index: [String: UInt32] = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, UInt32($0)) })
    private static let prefixIndex: [String: UInt32] = Dictionary(uniqueKeysWithValues: list.enumerated().map {
        (String($1.prefix(EnvelopeWordlist.uniquePrefixLength)), UInt32($0))
    })

    static func encode(_ key: [UInt8]) -> [String]? {
        guard key.count == 32 else { return nil }
        var words: [String] = []
        for i in 0..<8 {
            let x = UInt32(key[i * 4]) | UInt32(key[i * 4 + 1]) << 8 | UInt32(key[i * 4 + 2]) << 16 | UInt32(key[i * 4 + 3]) << 24
            let w1 = x % n
            let w2 = (x / n + w1) % n
            let w3 = (x / n / n + w2) % n
            words += [list[Int(w1)], list[Int(w2)], list[Int(w3)]]
        }
        words.append(words[checksumIndex(words)])
        return words
    }

    static func decode(_ input: [String]) -> [UInt8]? {
        let words = input.map { $0.lowercased() }
        guard words.count == 25 else { return nil }
        var indices: [UInt32] = []
        for word in words.prefix(24) {
            guard let i = index[word] ?? prefixIndex[String(word.prefix(EnvelopeWordlist.uniquePrefixLength))] else { return nil }
            indices.append(i)
        }
        var key: [UInt8] = []
        for i in 0..<8 {
            let w1 = UInt64(indices[i * 3]), w2 = UInt64(indices[i * 3 + 1]), w3 = UInt64(indices[i * 3 + 2])
            let n = UInt64(self.n)
            let value = w1 + n * (((n - w1) + w2) % n) + n * n * (((n - w2) + w3) % n)
            guard value % n == w1, value <= UInt64(UInt32.max) else { return nil }
            let x = UInt32(value)
            key += [UInt8(x & 0xff), UInt8(x >> 8 & 0xff), UInt8(x >> 16 & 0xff), UInt8(x >> 24 & 0xff)]
        }
        // The checksum word must match on its unique prefix.
        let checksum = words[checksumIndex(Array(words.prefix(24)))]
        guard checksum.prefix(EnvelopeWordlist.uniquePrefixLength) == words[24].prefix(EnvelopeWordlist.uniquePrefixLength) else { return nil }
        return key
    }

    private static func checksumIndex(_ words: [String]) -> Int {
        let trimmed = words.map { String($0.prefix(EnvelopeWordlist.uniquePrefixLength)) }.joined()
        return Int(CRC32.checksum(Array(trimmed.utf8)) % UInt32(words.count))
    }
}

/// CRC-32 (IEEE 802.3), as boost::crc_32_type.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Keys and address

/// Monero key math through wallet2's own C primitives (crypto-ops.c and
/// hash.c in the linked Monero library).
enum EnvelopeCrypto {
    /// Secret key mod l.
    static func reduce(_ bytes: [UInt8]) -> [UInt8] {
        var s = bytes
        s.withUnsafeMutableBufferPointer { monero_sc_reduce32($0.baseAddress!) }
        return s
    }

    /// A canonical scalar (< l) that is not zero.
    static func isCanonicalNonZero(_ s: [UInt8]) -> Bool {
        guard s.count == 32, s.contains(where: { $0 != 0 }) else { return false }
        return s.withUnsafeBufferPointer { monero_sc_check($0.baseAddress!) } == 0
    }

    static func keccak(_ data: [UInt8]) -> [UInt8] {
        var out = [CChar](repeating: 0, count: 32)
        data.withUnsafeBytes { input in
            out.withUnsafeMutableBufferPointer { monero_cn_fast_hash(input.baseAddress!, data.count, $0.baseAddress!) }
        }
        return out.map { UInt8(bitPattern: $0) }
    }

    /// wallet2's view key for a legacy seed: Keccak-256 of the spend key, mod l.
    static func viewKey(spendKey: [UInt8]) -> [UInt8] {
        reduce(keccak(spendKey))
    }

    /// The public key `s·G`.
    static func publicKey(_ secret: [UInt8]) -> [UInt8] {
        // ge_p3 is four field elements of ten int32 each: 160 bytes.
        var point = [UInt8](repeating: 0, count: 160)
        var out = [UInt8](repeating: 0, count: 32)
        secret.withUnsafeBufferPointer { s in
            point.withUnsafeMutableBytes { p in
                monero_ge_scalarmult_base(p.baseAddress!, s.baseAddress!)
            }
        }
        point.withUnsafeBytes { p in
            out.withUnsafeMutableBufferPointer { monero_ge_p3_tobytes($0.baseAddress!, p.baseAddress!) }
        }
        return out
    }

    /// The standard primary address of a legacy seed's spend key.
    static func address(spendKey: [UInt8], networkType: MoneroKit.NetworkType) -> String? {
        guard spendKey.count == 32 else { return nil }
        let prefix: UInt8 = networkType == .mainnet ? 18 : 53
        var data: [UInt8] = [prefix]
        data += publicKey(spendKey)
        data += publicKey(viewKey(spendKey: spendKey))
        data += keccak(data).prefix(4)
        return MoneroBase58.encode(data)
    }
}

/// Monero's block base58: 8-byte blocks as 11 characters, the last block
/// shorter.
enum MoneroBase58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let blockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11]

    static func encode(_ data: [UInt8]) -> String {
        var result = ""
        var offset = 0
        while offset < data.count {
            let block = data[offset..<min(offset + 8, data.count)]
            var value: UInt64 = 0
            for b in block { value = value << 8 | UInt64(b) }
            var chars = [Character](repeating: "1", count: blockSizes[block.count])
            var i = chars.count - 1
            while value > 0 && i >= 0 {
                chars[i] = alphabet[Int(value % 58)]
                value /= 58
                i -= 1
            }
            result.append(contentsOf: chars)
            offset += 8
        }
        return result
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    mutating func resetBytes() {
        for i in indices { self[i] = 0 }
    }
}

// MARK: - Monero C primitives (libMoneroCombined, C linkage)

@_silgen_name("sc_reduce32")
private func monero_sc_reduce32(_ s: UnsafeMutablePointer<UInt8>)

@_silgen_name("sc_check")
private func monero_sc_check(_ s: UnsafePointer<UInt8>) -> Int32

@_silgen_name("ge_scalarmult_base")
private func monero_ge_scalarmult_base(_ h: UnsafeMutableRawPointer, _ a: UnsafePointer<UInt8>)

@_silgen_name("ge_p3_tobytes")
private func monero_ge_p3_tobytes(_ s: UnsafeMutablePointer<UInt8>, _ h: UnsafeRawPointer)

@_silgen_name("cn_fast_hash")
private func monero_cn_fast_hash(_ data: UnsafeRawPointer, _ length: Int, _ hash: UnsafeMutablePointer<CChar>)
