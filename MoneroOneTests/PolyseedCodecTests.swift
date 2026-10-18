import XCTest
@testable import MoneroOne

/// The 16-word Polyseed decoder against external/polyseed/tests/tests.c.
final class PolyseedCodecTests: XCTestCase {

    static let phraseEn1 = "raven tail swear infant grief assist regular lamp "
        + "duck valid someone little harsh puppy airport language"
    static let phraseEn2 = "rave tail swea infan grie assi regul lamp "
        + "duck vali some litt hars pupp airp langua"
    static let phraseEn3 = "ravexxx tail swea infan grie assi regul lamp "
        + "duck vali some litt hars pupp airp langua"
    static let phraseEn4 = "raven tail swear infantile grief assist regular lamp "
        + "duck valid someone little harsh puppy airport language"
    static let phraseEn5 = "raven tail swear infant grief assist regular lamp "
        + "duck valid someone little harsh puppy airport language "
    /// tests.c spells es1 with accents; both normal forms must decode.
    static let phraseEs1NFC = "eje fin parte c\u{E9}lebre tab\u{FA} pesta\u{F1}a lienzo puma "
        + "prisi\u{F3}n hora regalo lengua existir l\u{E1}piz lote sonoro"
    static let phraseEs1NFD = "eje fin parte ce\u{301}lebre tabu\u{301} pestan\u{303}a lienzo puma "
        + "prisio\u{301}n hora regalo lengua existir la\u{301}piz lote sonoro"
    static let phraseEs2 = "eje fin parte celebre tabu pestana lienzo puma "
        + "prision hora regalo lengua existir lapiz lote sonoro"
    static let phraseEs3 = "eje fin part cele tabu pest lien puma "
        + "pris hora rega leng exis lapi lote sono"
    static let phraseEs4 = "ejexxx fin part cele tabu pest lien puma "
        + "pris hora rega leng exis lapi lote sono"
    static let phraseEs5 = "eje fin part cele tab pest lien puma "
        + "pris hora rega leng exis lapi lote sono"
    static let phraseEsMult = "impo sort usua cabi venu nobl oliv clim "
        + "cont barr marc auto prod vaca torn fati"
    static let phraseGarbage1 = "xxx xxx"
    static let phraseGarbage2 = String(repeating: "xxx ", count: 120)

    /// SEED_TIME1 (Dec 2021) encodes to birthday 1.
    static let en1Birthday: UInt = 1
    static let en1BirthdayTimestamp: UInt64 = 1_638_397_746

    private var english: Int { SeedWordlists.polyseedOrder.firstIndex(of: "English")! }
    private var spanish: Int { SeedWordlists.polyseedOrder.firstIndex(of: "Spanish")! }

    private func data(_ status: PolyseedCodec.Status, file: StaticString = #filePath, line: UInt = #line) -> (Int, PolyseedCodec.SeedData)? {
        guard case .ok(let language, _, let data) = status else {
            XCTFail("expected OK, got \(status)", file: file, line: line)
            return nil
        }
        return (language, data)
    }

    func testListsLoadInPolyseedOrder() {
        XCTAssertEqual(SeedWordlists.polyseed.map(\.englishName), SeedWordlists.polyseedOrder)
        for list in SeedWordlists.polyseed {
            XCTAssertEqual(list.words.count, 2048, list.englishName)
            // polyseed_lang_check: every word is NFKD.
            XCTAssertTrue(list.words.allSatisfy { $0.decomposedStringWithCompatibilityMapping.utf8.elementsEqual($0.utf8) }, list.englishName)
        }
        XCTAssertEqual(SeedWordlists.polyseed[SeedWordlists.polyseedOrder.firstIndex(of: "Japanese")!].separator, "\u{3000}")
    }

    func testSortedListsAreSortedForTheirComparer() {
        for list in SeedWordlists.polyseed where list.isSorted {
            for i in 1..<list.cWords.count {
                XCTAssertLessThan(PolyseedCodec.compare(list.cWords[i - 1], list.cWords[i], list: list), 0,
                                  "\(list.englishName) at \(i)")
            }
        }
    }

    func testBinarySearchAgreesWithLinearSearch() {
        var rng = SplitMix64(seed: 0xB5)
        for list in SeedWordlists.polyseed {
            for (i, word) in list.words.enumerated() {
                let key = PolyseedCodec.cString(word)
                XCTAssertEqual(PolyseedCodec.search(key, in: list), i, "\(list.englishName) \(word)")
                // The linear reference costs 2048 compares; sample it.
                guard i % 16 == 0 else { continue }
                XCTAssertEqual(PolyseedCodec.linearSearch(key, in: list), i, "\(list.englishName) \(word)")
                let scalars = Array(word.unicodeScalars)
                for length in [1, 2, 3, 4, 5] where length < scalars.count {
                    var prefix = String.UnicodeScalarView()
                    prefix.append(contentsOf: scalars.prefix(length))
                    let p = PolyseedCodec.cString(String(prefix))
                    XCTAssertEqual(PolyseedCodec.search(p, in: list), PolyseedCodec.linearSearch(p, in: list),
                                   "\(list.englishName) prefix of \(word)")
                }
            }
            for _ in 0..<300 {
                let length = Int.random(in: 1...8, using: &rng)
                let token = String((0..<length).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122, using: &rng))) })
                let key = PolyseedCodec.cString(token)
                XCTAssertEqual(PolyseedCodec.search(key, in: list), PolyseedCodec.linearSearch(key, in: list), token)
            }
        }
    }

    // MARK: - tests.c decode cases

    func testDecodeEn1() {
        guard let (language, seed) = data(PolyseedCodec.decode(Self.phraseEn1)) else { return }
        XCTAssertEqual(language, english)
        XCTAssertEqual(seed.birthday, Self.en1Birthday)
        XCTAssertEqual(seed.features, 0)
        XCTAssertFalse(seed.isEncrypted)
        XCTAssertEqual(seed.birthdayTimestamp, Self.en1BirthdayTimestamp)
        XCTAssertEqual(seed.birthdayDate, Date(timeIntervalSince1970: 1_638_397_746))
        // test_create1: birthday <= SEED_TIME1 < birthday + 2630000
        XCTAssertLessThanOrEqual(seed.birthdayTimestamp, 1_638_446_400)
        XCTAssertGreaterThan(seed.birthdayTimestamp + 2_630_000, 1_638_446_400)
    }

    func testDecodeEn2PrefixesGiveTheSameSeed() {
        guard let (_, en1) = data(PolyseedCodec.decode(Self.phraseEn1)),
              let (language, en2) = data(PolyseedCodec.decode(Self.phraseEn2)) else { return }
        XCTAssertEqual(language, english)
        XCTAssertEqual(en2, en1)
    }

    func testDecodeSuffixesFail() {
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEn3), .errLang)
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEn4), .errLang)
    }

    func testDecodeTrailingSpace() {
        guard let (language, _) = data(PolyseedCodec.decode(Self.phraseEn5)) else { return }
        XCTAssertEqual(language, english)
    }

    func testDecodeWithAnotherCoinFailsTheChecksum() {
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEn1, coin: 1), .errChecksum)
    }

    func testDecodeSpanish() {
        guard let (l1, nfc) = data(PolyseedCodec.decode(Self.phraseEs1NFC)),
              let (l2, nfd) = data(PolyseedCodec.decode(Self.phraseEs1NFD)),
              let (l3, noAccent) = data(PolyseedCodec.decode(Self.phraseEs2)),
              let (l4, prefix) = data(PolyseedCodec.decode(Self.phraseEs3)) else { return }
        XCTAssertEqual([l1, l2, l3, l4], [spanish, spanish, spanish, spanish])
        XCTAssertEqual(nfd, nfc)
        XCTAssertEqual(noAccent, nfc)
        XCTAssertEqual(prefix, nfc)
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEs4), .errLang)
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEs5), .errLang)
    }

    func testDecodeAmbiguousLanguage() {
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEsMult), .errMultLang)
        guard case .ok = PolyseedCodec.decodeExplicit(Self.phraseEsMult, language: spanish) else {
            return XCTFail("decode_explicit(es) must succeed")
        }
    }

    func testDecodeGarbage() {
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseGarbage1), .errNumWords)
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseGarbage2), .errNumWords)
        XCTAssertEqual(PolyseedCodec.decode(""), .errNumWords)
    }

    func testStrSplitEdgeCases() {
        let words = Self.phraseEn1.split(separator: " ").map(String.init)
        // A double space makes an empty word, so 15 real words + "" = 16.
        let doubled = words.prefix(15).joined(separator: " ") + "  "
        XCTAssertEqual(PolyseedCodec.split(PolyseedCodec.cString(doubled)).count, 16)
        // 17 words.
        XCTAssertEqual(PolyseedCodec.split(PolyseedCodec.cString(Self.phraseEn1 + " duck")).count, 17)
        XCTAssertEqual(PolyseedCodec.decode(Self.phraseEn1 + " duck"), .errNumWords)
    }

    // MARK: - Round trips and single-word changes

    func testRoundTripInEveryLanguage() {
        guard let (_, seed) = data(PolyseedCodec.decode(Self.phraseEn1)) else { return }
        let indices = PolyseedCodec.encode(seed)
        for (li, list) in SeedWordlists.polyseed.enumerated() {
            let words = indices.map { list.words[$0] }
            for separator in [" ", list.separator] {
                let phrase = words.joined(separator: separator)
                guard let (language, decoded) = data(PolyseedCodec.decode(phrase)) else { continue }
                XCTAssertEqual(language, li, list.englishName)
                XCTAssertEqual(decoded, seed, list.englishName)
            }
            // NFC input (what a person types) decodes the same.
            let composed = words.joined(separator: " ").precomposedStringWithCanonicalMapping
            guard let (language, decoded) = data(PolyseedCodec.decode(composed)) else { continue }
            XCTAssertEqual(language, li, list.englishName)
            XCTAssertEqual(decoded, seed, list.englishName)
        }
    }

    func testEncodeReproducesEn1() {
        guard let (_, seed) = data(PolyseedCodec.decode(Self.phraseEn1)) else { return }
        let list = SeedWordlists.polyseed[english]
        XCTAssertEqual(PolyseedCodec.encode(seed).map { list.words[$0] }.joined(separator: " "), Self.phraseEn1)
    }

    func testChangingAnySingleWordOfEn1Fails() {
        let list = SeedWordlists.polyseed[english]
        let words = Self.phraseEn1.split(separator: " ").map(String.init)
        for position in words.indices {
            let index = list.words.firstIndex(of: words[position])!
            for delta in [1, 7, 1000] {
                var changed = words
                changed[position] = list.words[(index + delta) % 2048]
                if case .ok = PolyseedCodec.decode(changed.joined(separator: " ")) {
                    XCTFail("word \(position + 1) changed by \(delta) still decodes")
                }
            }
        }
    }

    func testFeatureBits() {
        guard let (_, seed) = data(PolyseedCodec.decode(Self.phraseEn1)) else { return }
        let list = SeedWordlists.polyseed[english]

        var encrypted = seed
        encrypted.features = PolyseedCodec.encryptedMask
        let encryptedPhrase = PolyseedCodec.encode(encrypted).map { list.words[$0] }.joined(separator: " ")
        guard let (_, decoded) = data(PolyseedCodec.decode(encryptedPhrase)) else { return }
        XCTAssertTrue(decoded.isEncrypted)

        for reserved: UInt in [1, 2, 4, 8] {
            var unsupported = seed
            unsupported.features = reserved
            let phrase = PolyseedCodec.encode(unsupported).map { list.words[$0] }.joined(separator: " ")
            XCTAssertEqual(PolyseedCodec.decode(phrase), .errUnsupported, "feature \(reserved)")
        }
    }

    func testNormalizationLimit() {
        // ASCII is cut at 359 bytes like utf8_nfkd_lazy; non-ASCII above 360
        // bytes fails like wallet2's utf8proc wrapper.
        XCTAssertEqual(PolyseedCodec.decompose(String(repeating: "a", count: 400))?.count, 360)
        XCTAssertNil(PolyseedCodec.decompose(String(repeating: "\u{AC00}", count: 121)))
        XCTAssertNotNil(PolyseedCodec.decompose(String(repeating: "\u{E9}", count: 100)))
    }

    func testBirthdayDecode() {
        XCTAssertEqual(PolyseedCodec.birthdayDecode(0), 1_635_768_000)
        XCTAssertEqual(PolyseedCodec.birthdayDecode(1), 1_638_397_746)
        XCTAssertEqual(PolyseedCodec.birthdayDecode(1023), 1_635_768_000 + 1023 * 2_629_746)
    }
}
