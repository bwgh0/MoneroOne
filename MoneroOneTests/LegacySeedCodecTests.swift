import XCTest
@testable import MoneroOne

/// The 25-word legacy checks against wallet2's electrum-words.cpp rules.
final class LegacySeedCodecTests: XCTestCase {

    /// Spec vector (checksum verified against wallet2).
    static let vector = ("sequence atlas unveil summon pebbles tuesday beer rudely snake rockets different "
        + "fuselage woven tagged bested dented vegan hover rapid fawns obvious muppet randomly seasons randomly")
        .split(separator: " ").map(String.init)

    private var english: Int { SeedWordlists.legacyEnglishIndex }

    // MARK: - Building blocks

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(LegacySeedCodec.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(LegacySeedCodec.crc32([]), 0)
    }

    func testUtf8PrefixCountsCodePoints() {
        XCTAssertEqual(LegacySeedCodec.utf8Prefix(Array("abcdef".utf8), 3), Array("abc".utf8))
        XCTAssertEqual(LegacySeedCodec.utf8Prefix(Array("ab".utf8), 3), Array("ab".utf8))
        XCTAssertEqual(LegacySeedCodec.utf8Prefix(Array("äöüß".utf8), 2), Array("äö".utf8))
        XCTAssertEqual(LegacySeedCodec.utf8Prefix(Array("日本語です".utf8), 3), Array("日本語".utf8))
        XCTAssertEqual(LegacySeedCodec.utf8Prefix(Array("abc".utf8), 0), [])
    }

    func testListsLoadInWallet2Order() {
        XCTAssertEqual(SeedWordlists.legacy.map(\.englishName), SeedWordlists.legacyOrder)
        for list in SeedWordlists.legacy {
            XCTAssertEqual(list.words.count, 1626, list.englishName)
            XCTAssertEqual(list.keys.count, 1626, list.englishName)
        }
        // English (old) has duplicate prefixes; the last word wins, as in
        // wallet2's populate_maps.
        let old = SeedWordlists.legacy[SeedWordlists.legacyOrder.firstIndex(of: "English (old)")!]
        XCTAssertLessThan(old.indexByLowerKey.count, 1626)
        for (i, key) in old.keys.enumerated() {
            let winner = old.indexByLowerKey[SeedWordlists.lowerBytes(key)]!
            XCTAssertGreaterThanOrEqual(winner, i)
        }
    }

    func testTripleCheckMatchesUInt64Arithmetic() {
        var rng = SplitMix64(seed: 0x7121)
        let n: UInt64 = 1626
        for _ in 0..<20_000 {
            let w1 = UInt64.random(in: 0..<n, using: &rng)
            let w2 = UInt64.random(in: 0..<n, using: &rng)
            let w3 = UInt64.random(in: 0..<n, using: &rng)
            let exact = w1 + n * ((n - w1 + w2) % n) + n * n * ((n - w2 + w3) % n)
            let fitsInUInt32 = exact < (1 << 32)
            XCTAssertEqual(
                LegacySeedCodec.tripleIsValid(UInt32(w1), UInt32(w2), UInt32(w3), wordListLength: UInt32(n)),
                fitsInUInt32
            )
        }
        XCTAssertFalse(LegacySeedCodec.tripleIsValid(5, 0, 1625, wordListLength: 1626))
        XCTAssertTrue(LegacySeedCodec.tripleIsValid(5, 0, 0, wordListLength: 1626))
    }

    // MARK: - Spec vectors

    func testEnglishVectorIsValid() {
        guard case .valid(let language, let words) = LegacySeedCodec.decode(Self.vector) else {
            return XCTFail("spec vector must be valid")
        }
        XCTAssertEqual(language, english)
        XCTAssertEqual(words, Self.vector)
    }

    func testThreeLetterPrefixesResolveToTheFullWords() {
        let prefixes = Self.vector.map { String($0.prefix(3)) }
        XCTAssertEqual(LegacySeedCodec.decode(prefixes), .valid(language: english, words: Self.vector))
    }

    func testAnySuffixAfterThePrefixMatchesLikeWallet2() {
        // "abbxy" is "abbey": wallet2 compares only the unique prefix.
        let mangled = Self.vector.map { String($0.prefix(3)) + "xyz" }
        XCTAssertEqual(LegacySeedCodec.decode(mangled), .valid(language: english, words: Self.vector))
        let list = SeedWordlists.legacy[english]
        XCTAssertEqual(LegacySeedCodec.index(of: Array("abbxy".utf8), in: list).map { list.words[$0] }, "abbey")
    }

    func testSwappingWordsOneAndTwoFailsTheChecksum() {
        var swapped = Self.vector
        swapped.swapAt(0, 1)
        XCTAssertEqual(LegacySeedCodec.decode(swapped), .checksumFailed(language: english))
    }

    func testUnknownWordFindsNoLanguage() {
        var phrase = Self.vector
        phrase[4] = "xyzzy"
        XCTAssertEqual(LegacySeedCodec.decode(phrase), .unknownWords)
    }

    func testWrongCount() {
        XCTAssertEqual(LegacySeedCodec.decode(Array(Self.vector.prefix(24))), .wrongCount)
    }

    // MARK: - Every language

    func testRandomKeysRoundTripInEveryLanguage() {
        var rng = SplitMix64(seed: 0x5EED)
        let lists = SeedWordlists.legacy
        for (li, list) in lists.enumerated() {
            var checked = 0
            for _ in 0..<16 {
                let key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
                guard let words = LegacySeedCodec.encode(key, list: list) else {
                    XCTFail("encode failed for \(list.englishName)")
                    continue
                }
                let tokens = words.map { $0.lowercased() }
                // wallet2 tries the lists in order; skip the rare phrase an
                // earlier list also holds in full.
                let shadowed = lists[..<li].contains { other in
                    tokens.allSatisfy { LegacySeedCodec.index(of: Array($0.utf8), in: other) != nil }
                }
                if shadowed { continue }

                guard case .valid(let language, let decoded) = LegacySeedCodec.decode(tokens) else {
                    XCTFail("\(list.englishName): random key did not decode")
                    continue
                }
                XCTAssertEqual(language, li, list.englishName)
                let expected = tokens.map { list.words[LegacySeedCodec.index(of: Array($0.utf8), in: list)!] }
                XCTAssertEqual(decoded, expected, list.englishName)
                // Without a shadowed duplicate prefix, the key comes back.
                if decoded == words {
                    let indices = decoded.dropLast().map { list.words.firstIndex(of: $0)! }
                    XCTAssertEqual(Self.keyBytes(indices), key, list.englishName)
                }
                checked += 1
            }
            XCTAssertGreaterThanOrEqual(checked, 8, "\(list.englishName): too many shadowed phrases")
        }
    }

    func testOverflowingTripleWithAGoodChecksumIsInvalid() {
        let list = SeedWordlists.legacy[english]
        var rng = SplitMix64(seed: 99)
        let key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var words = Array(LegacySeedCodec.encode(key, list: list)!.dropLast())
        words[0] = list.words[5]
        words[1] = list.words[0]
        words[2] = list.words[1625]
        let checksum = LegacySeedCodec.checksumIndex(words.map { Array($0.utf8) }, list)!
        let phrase = words + [words[checksum]]
        XCTAssertEqual(LegacySeedCodec.decode(phrase), .invalidTriple(language: english))
    }

    // MARK: - Helpers

    /// The words_to_bytes arithmetic for a list of 24 indices.
    static func keyBytes(_ indices: [Int]) -> [UInt8] {
        let n: UInt32 = 1626
        var out: [UInt8] = []
        for i in 0..<(indices.count / 3) {
            let w1 = UInt32(indices[i * 3])
            let w2 = UInt32(indices[i * 3 + 1])
            let w3 = UInt32(indices[i * 3 + 2])
            let w0 = w1 &+ n &* (((n &- w1) &+ w2) % n) &+ n &* n &* (((n &- w2) &+ w3) % n)
            out += [UInt8(w0 & 0xFF), UInt8((w0 >> 8) & 0xFF), UInt8((w0 >> 16) & 0xFF), UInt8(w0 >> 24)]
        }
        return out
    }
}

/// Deterministic generator so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
