import XCTest
import HdWalletKit
@testable import MoneroOne

/// The validator the seed entry screen and WalletManager share.
final class SeedPhraseValidatorTests: XCTestCase {

    private let legacy = LegacySeedCodecTests.vector
    private let bip39Valid = Array(repeating: "abandon", count: 23) + ["art"]
    private var en1: [String] { PolyseedCodecTests.phraseEn1.split(separator: " ").map(String.init) }
    private var en2: [String] { PolyseedCodecTests.phraseEn2.split(separator: " ").map(String.init) }

    // MARK: - Legacy

    func testLegacyVector() {
        guard case .valid(let phrase) = SeedPhraseValidator.validate(legacy, format: .legacy) else {
            return XCTFail("legacy vector must be valid")
        }
        XCTAssertEqual(phrase.words, legacy)
        XCTAssertNil(phrase.birthday)
    }

    func testLegacyPrefixesCanonicalize() {
        let typed = legacy.map { String($0.prefix(3)).uppercased() }
        guard case .valid(let phrase) = SeedPhraseValidator.validate(typed, format: .legacy) else {
            return XCTFail("3-letter prefixes must be valid")
        }
        XCTAssertEqual(phrase.words, legacy)
    }

    func testLegacyChecksumAndUnknownWord() {
        var swapped = legacy
        swapped.swapAt(0, 1)
        XCTAssertEqual(SeedPhraseValidator.validate(swapped, format: .legacy), .invalid)

        var unknown = legacy
        unknown[4] = "xyzzy"
        XCTAssertEqual(SeedPhraseValidator.validate(unknown, format: .legacy), .unknownWords([4]))
    }

    func testLegacyWordFromAnotherLanguageIsMarkedAgainstTheBestList() {
        // 24 English words and one Spanish word: wallet2 finds no language,
        // the marks go against English.
        var mixed = legacy
        mixed[9] = "abeja"
        XCTAssertTrue(SeedPhraseValidator.match("abeja", format: .legacy).isKnown)
        XCTAssertEqual(SeedPhraseValidator.validate(mixed, format: .legacy), .unknownWords([9]))
    }

    func testLegacyGermanCanonicalWordsKeepTheirCase() {
        let german = SeedWordlists.legacy[SeedWordlists.legacyOrder.firstIndex(of: "German")!]
        var rng = SplitMix64(seed: 0xDE)
        let key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let words = LegacySeedCodec.encode(key, list: german)!
        guard case .valid(let phrase) = SeedPhraseValidator.validate(words.map { $0.lowercased() }, format: .legacy) else {
            return XCTFail("lowercased German phrase must be valid")
        }
        XCTAssertEqual(phrase.words, words)
    }

    // MARK: - Polyseed

    func testPolyseedEn1() {
        guard case .valid(let phrase) = SeedPhraseValidator.validate(en1, format: .polyseed) else {
            return XCTFail("g_phrase_en1 must be valid")
        }
        XCTAssertEqual(phrase.words, en1)
        XCTAssertEqual(phrase.birthday, Date(timeIntervalSince1970: 1_638_397_746))
    }

    func testPolyseedBirthdayFormatsAsDecember2021() {
        guard case .valid(let phrase) = SeedPhraseValidator.validate(en1, format: .polyseed),
              let birthday = phrase.birthday else {
            return XCTFail("g_phrase_en1 must be valid")
        }
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.locale = Locale(identifier: "en_US")
        style.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(birthday.formatted(style), "December 2021")
    }

    func testPolyseedPrefixesCanonicalize() {
        guard case .valid(let phrase) = SeedPhraseValidator.validate(en2, format: .polyseed) else {
            return XCTFail("g_phrase_en2 must be valid")
        }
        XCTAssertEqual(phrase.words, en1)
    }

    func testPolyseedSpanishWithoutAccentsGivesListWords() {
        let typed = PolyseedCodecTests.phraseEs2.split(separator: " ").map(String.init)
        guard case .valid(let phrase) = SeedPhraseValidator.validate(typed, format: .polyseed) else {
            return XCTFail("es2 must be valid")
        }
        let expected = PolyseedCodecTests.phraseEs1NFD.split(separator: " ").map(String.init)
        XCTAssertEqual(phrase.words.map { Array($0.utf8) }, expected.map { Array($0.utf8) })
    }

    func testPolyseedFailures() {
        var changed = en1
        changed[3] = "lamp"
        XCTAssertEqual(SeedPhraseValidator.validate(changed, format: .polyseed), .invalid)

        var unknown = en1
        unknown[6] = "xyzzy"
        XCTAssertEqual(SeedPhraseValidator.validate(unknown, format: .polyseed), .unknownWords([6]))

        let mult = PolyseedCodecTests.phraseEsMult.split(separator: " ").map(String.init)
        XCTAssertEqual(SeedPhraseValidator.validate(mult, format: .polyseed), .invalid)
    }

    func testPolyseedPassphrase() {
        guard case .ok(_, _, var seed) = PolyseedCodec.decode(PolyseedCodecTests.phraseEn1) else {
            return XCTFail("en1 must decode")
        }
        seed.features = PolyseedCodec.encryptedMask
        let list = SeedWordlists.polyseed[SeedWordlists.polyseedEnglishIndex]
        let words = PolyseedCodec.encode(seed).map { list.words[$0] }
        XCTAssertEqual(SeedPhraseValidator.validate(words, format: .polyseed), .passphrase)

        seed.features = 1
        let reserved = PolyseedCodec.encode(seed).map { list.words[$0] }
        XCTAssertEqual(SeedPhraseValidator.validate(reserved, format: .polyseed), .invalid)
    }

    // MARK: - BIP39

    func testBip39() {
        XCTAssertEqual(
            SeedPhraseValidator.validate(bip39Valid, format: .bip39),
            .valid(.init(words: bip39Valid, language: Bip39Lists.englishIndex, birthday: nil))
        )
        XCTAssertEqual(SeedPhraseValidator.validate(Array(repeating: "abandon", count: 24), format: .bip39), .invalid)

        var unknown = bip39Valid
        unknown[23] = "xyzzy"
        XCTAssertEqual(SeedPhraseValidator.validate(unknown, format: .bip39), .unknownWords([23]))
    }

    func testBip39PrefixExpansion() {
        let typed = Array(repeating: "ABAN", count: 23) + ["art"]
        guard case .valid(let phrase) = SeedPhraseValidator.validate(typed, format: .bip39) else {
            return XCTFail("4-letter prefixes must expand")
        }
        XCTAssertEqual(phrase.words, bip39Valid)
        // Three letters are not enough for BIP39.
        XCTAssertFalse(SeedPhraseValidator.match("aba", format: .bip39).isKnown)
    }

    func testBip39GeneratedPhrasesAreValid() throws {
        for language in [Mnemonic.Language.english, .spanish, .japanese, .french] {
            let words = try Mnemonic.generate(wordCount: .twentyFour, language: language)
            guard case .valid(let phrase) = SeedPhraseValidator.validate(words, format: .bip39) else {
                return XCTFail("\(language) phrase must be valid")
            }
            XCTAssertTrue(Mnemonic.isValid(words: phrase.words))
            // NFC input (what a keyboard types) validates too.
            let composed = words.map { $0.precomposedStringWithCanonicalMapping }
            guard case .valid = SeedPhraseValidator.validate(composed, format: .bip39) else {
                return XCTFail("\(language) NFC phrase must be valid")
            }
        }
    }

    // MARK: - Counts

    func testIncomplete() {
        XCTAssertEqual(SeedPhraseValidator.validate(Array(legacy.prefix(24)), format: .legacy), .incomplete)
        var withEmpty = legacy
        withEmpty[3] = " "
        XCTAssertEqual(SeedPhraseValidator.validate(withEmpty, format: .legacy), .incomplete)
        XCTAssertEqual(SeedPhraseValidator.validate(legacy, format: .bip39), .incomplete)
    }

    // MARK: - One word at a time

    func testMatchAndCanonicalForm() {
        XCTAssertEqual(SeedPhraseValidator.match("abbxy", format: .legacy).canonical, "abbey")
        XCTAssertEqual(SeedPhraseValidator.match("RAVE", format: .polyseed).canonical, "raven")
        XCTAssertEqual(SeedPhraseValidator.match("pestana", format: .polyseed).canonical, "pesta\u{F1}a")
        // Spanish "célebre" and Italian "celebre": two words, no canonical form.
        let celebre = SeedPhraseValidator.match("celebre", format: .polyseed)
        XCTAssertEqual(celebre.languages.count, 2)
        XCTAssertNil(celebre.canonical)
        XCTAssertEqual(SeedPhraseValidator.match("aban", format: .bip39).canonical, "abandon")
        XCTAssertFalse(SeedPhraseValidator.match("xyzzy", format: .legacy).isKnown)
        XCTAssertFalse(SeedPhraseValidator.match("", format: .legacy).isKnown)
    }

    /// A full list word never turns into a different word on commit.
    func testCommitNeverReplacesAFullListWord() {
        for format in SeedFormat.allCases {
            for language in 0..<SeedPhraseValidator.languageCount(format) {
                let words: [String]
                switch format {
                case .legacy:
                    let list = SeedWordlists.legacy[language]
                    // English (old) duplicate prefixes resolve to the last
                    // word in wallet2 too; skip the shadowed ones.
                    words = list.words.enumerated().filter { i, _ in
                        list.indexByLowerKey[SeedWordlists.lowerBytes(list.keys[i])] == i
                    }.map(\.element)
                case .polyseed:
                    words = SeedWordlists.polyseed[language].words
                case .bip39:
                    words = Bip39Lists.lists[language].words
                }
                for word in words.enumerated().filter({ $0.offset % 4 == 0 }).map(\.element) {
                    let committed = SeedPhraseValidator.canonicalOnCommit(word.lowercased(), format: format, committed: [])
                    let allowed = [SeedPhraseValidator.displayForm(word), SeedPhraseValidator.normalize(word)]
                    XCTAssertTrue(allowed.contains(committed), "\(format) \(language): \(word) -> \(committed)")
                }
            }
        }
    }

    func testCommitKeepsUnknownAndAmbiguousText() {
        XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit("Xyzzy", format: .legacy, committed: []), "xyzzy")
        XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit("seq", format: .legacy, committed: []), "sequence")
    }

    /// "bee" is a full English (old) word and the prefix of English "beer".
    /// Alone it stays; in an English phrase it becomes "beer".
    func testCommitFollowsTheActiveLanguage() {
        XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit("bee", format: .legacy, committed: []), "bee")
        let english = Array(LegacySeedCodecTests.vector.prefix(6))
        XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit("bee", format: .legacy, committed: english), "beer")
    }

    func testActiveLanguageAndSuggestions() {
        XCTAssertEqual(SeedPhraseValidator.activeLanguage([], format: .legacy), SeedWordlists.legacyEnglishIndex)
        let spanish = SeedWordlists.polyseedOrder.firstIndex(of: "Spanish")!
        let spanishWords = PolyseedCodecTests.phraseEs2.split(separator: " ").map(String.init)
        XCTAssertEqual(SeedPhraseValidator.activeLanguage(Array(spanishWords.prefix(6)), format: .polyseed), spanish)

        let suggestions = SeedPhraseValidator.suggestions(for: "ab", format: .bip39, committed: [])
        XCTAssertEqual(suggestions, ["abandon", "ability", "able"])
        XCTAssertEqual(SeedPhraseValidator.suggestions(for: "abbxy", format: .legacy, committed: []).first, "abbey")
        XCTAssertTrue(SeedPhraseValidator.suggestions(for: "", format: .legacy, committed: []).isEmpty)
        let accented = SeedPhraseValidator.suggestions(for: "celeb", format: .polyseed, committed: Array(spanishWords.prefix(6)))
        XCTAssertEqual(accented.first, "c\u{E9}lebre")
        XCTAssertLessThanOrEqual(SeedPhraseValidator.suggestions(for: "a", format: .legacy, committed: []).count, 3)
    }

    // MARK: - Paste parser

    func testPasteNumberedLists() {
        let words = ["alpha", "bravo", "charlie"]
        XCTAssertEqual(SeedPasteParser.parse("1. alpha\n2. bravo\n3. charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("1) alpha 2) bravo 3) charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("#1 alpha #2 bravo #3 charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("1: alpha\t2: bravo\t3: charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("1.alpha 2.bravo 3.charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("(1) alpha (2) bravo (3) charlie"), words)
    }

    func testPasteSeparatorsCaseAndPunctuation() {
        let words = ["alpha", "bravo", "charlie"]
        XCTAssertEqual(SeedPasteParser.parse("alpha, bravo, charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("alpha;bravo;charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("  ALPHA  Bravo\t\tcharlie.  "), words)
        XCTAssertEqual(SeedPasteParser.parse("\"alpha bravo charlie\""), words)
        XCTAssertEqual(SeedPasteParser.parse("“alpha” ‘bravo’ «charlie»"), words)
        XCTAssertEqual(SeedPasteParser.parse("alpha\u{3000}bravo\u{3000}charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("alpha\r\nbravo\u{00A0}charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("• alpha\n• bravo\n- charlie"), words)
        XCTAssertEqual(SeedPasteParser.parse("ＡＬＰＨＡ bravo charlie"), words)
    }

    func testPasteKeepsNonLatinWords() {
        XCTAssertEqual(SeedPasteParser.parse("1. あいこくしん 2. 가격"), ["あいこくしん", "가격"])
        XCTAssertEqual(SeedPasteParser.parse("célebre, tabú"), ["célebre", "tabú"])
    }

    func testPasteFullPhrases() {
        let numbered = legacy.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        XCTAssertEqual(SeedPasteParser.parse(numbered), legacy)
        XCTAssertEqual(SeedPasteParser.parse(PolyseedCodecTests.phraseEn1.uppercased() + "."), en1)
    }
}

/// WalletManager must refuse bad seeds and save list words.
@MainActor
final class SeedRestoreDefenseTests: XCTestCase {
    var walletManager: WalletManager!

    override func setUp() async throws {
        walletManager = WalletManager()
    }

    override func tearDown() async throws {
        walletManager.deleteAllWallets()
        walletManager = nil
    }

    /// A wallet restored before the seed entry screen kept the phrase as
    /// typed (wallet2 took "SEQ" for "sequence"), so its derived ID hashes
    /// that text. Restoring the same phrase spelled out is still a duplicate,
    /// and the check leaves the stored seed and its ID alone.
    func testDuplicateCheckComparesCanonicalForms() async throws {
        let canonical = LegacySeedCodecTests.vector
        var typed = canonical.map { String($0.prefix(3)) }
        typed[0] = typed[0].uppercased()
        try walletManager.addWallet(name: "Typed", mnemonic: typed, pin: "1234")
        let storedId = walletManager.wallets.first?.derivedWalletId
        XCTAssertEqual(storedId, MoneroWallet.walletCacheId(seedPhrase: typed.joined(separator: " "), resetSuffix: nil, networkType: walletManager.networkType))

        await assertThrows(.duplicateWallet(existingName: "Typed")) {
            try await self.walletManager.checkForDuplicateSeed(seedPhrase: canonical.joined(separator: " "), pin: "1234")
        }
        await assertThrows(.duplicateWallet(existingName: "Typed")) {
            try await self.walletManager.restoreWallet(mnemonic: canonical, pin: "1234")
        }

        // Comparison only: one wallet, its seed and ID as stored.
        XCTAssertEqual(walletManager.wallets.count, 1)
        XCTAssertEqual(walletManager.wallets.first?.derivedWalletId, storedId)
        XCTAssertEqual(try walletManager.getSeedPhrase(pin: "1234"), typed)

        // Another phrase of the same type is not a duplicate.
        let other = try XCTUnwrap(LegacySeedCodec.encode([UInt8](repeating: 7, count: 32), list: SeedWordlists.legacy[SeedWordlists.legacyEnglishIndex]))
        XCTAssertNotEqual(other, canonical)
        try await walletManager.checkForDuplicateSeed(seedPhrase: other.joined(separator: " "), pin: "1234")
    }

    /// The keychain reads behind the restore check (about 0.2 s a wallet)
    /// run off the main actor: a main-actor ticker keeps running while the
    /// check reads five wallets of the same type.
    func testDuplicateCheckLeavesTheMainActorFree() async throws {
        let list = SeedWordlists.legacy[SeedWordlists.legacyEnglishIndex]
        for i in 1...5 {
            let words = try XCTUnwrap(LegacySeedCodec.encode([UInt8](repeating: UInt8(i), count: 32), list: list))
            try walletManager.addWallet(name: "Wallet \(i)", mnemonic: words, pin: "1234")
        }
        let other = try XCTUnwrap(LegacySeedCodec.encode([UInt8](repeating: 9, count: 32), list: list))

        let ticks = MainActorTicks()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.record()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let start = Date()
        try await walletManager.checkForDuplicateSeed(seedPhrase: other.joined(separator: " "), pin: "1234")
        let end = Date()
        let ticksDuringCheck = ticks.count
        ticker.cancel()

        let elapsed = end.timeIntervalSince(start)
        let longestGap = ticks.longestGap(from: start, to: end)
        print("Duplicate check, 5 wallets: \(String(format: "%.3f", elapsed)) s; longest main-actor gap \(String(format: "%.3f", longestGap)) s; \(ticksDuringCheck) ticks")
        XCTAssertGreaterThan(elapsed, 0.25, "the check read five wallets")
        XCTAssertGreaterThan(ticksDuringCheck, 10)
        XCTAssertLessThan(longestGap, 0.2, "the main actor waited on the check")
        XCTAssertEqual(walletManager.wallets.count, 5)
    }

    func testRestoreSavesCanonicalWords() async throws {
        let typed = Array(repeating: "aban", count: 23) + ["art"]
        try await walletManager.restoreWallet(mnemonic: typed, pin: "1234")
        XCTAssertEqual(try walletManager.getSeedPhrase(pin: "1234"), Array(repeating: "abandon", count: 23) + ["art"])
    }

    func testRestoreRejectsBadChecksums() async {
        var legacy = LegacySeedCodecTests.vector
        legacy.swapAt(0, 1)
        await assertThrows(.invalidMnemonic) {
            try await self.walletManager.restoreWallet(mnemonic: legacy, pin: "1234")
        }

        var polyseed = PolyseedCodecTests.phraseEn1.split(separator: " ").map(String.init)
        polyseed[0] = "tail"
        await assertThrows(.invalidMnemonic) {
            try await self.walletManager.restoreWallet(mnemonic: polyseed, pin: "1234")
        }
        XCTAssertFalse(walletManager.hasWallet)
    }

    /// `XCTAssertThrowsError` for async calls.
    private func assertThrows(_ expected: WalletError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WalletError, expected, file: file, line: line)
        }
    }

    func testValidateMnemonicUsesTheValidator() {
        XCTAssertTrue(walletManager.validateMnemonic(LegacySeedCodecTests.vector))
        XCTAssertTrue(walletManager.validateMnemonic(PolyseedCodecTests.phraseEn1.split(separator: " ").map(String.init)))
        XCTAssertFalse(walletManager.validateMnemonic(Array(repeating: "abandon", count: 24)))
        XCTAssertFalse(walletManager.validateMnemonic(Array(repeating: "raven", count: 16)))
        XCTAssertFalse(walletManager.validateMnemonic([]))
    }
}

/// When a main-actor task got to run.
@MainActor
private final class MainActorTicks {
    private var times: [Date] = []

    var count: Int { times.count }

    func record() {
        times.append(Date())
    }

    /// The longest stretch between `start` and `end` without a tick.
    func longestGap(from start: Date, to end: Date) -> TimeInterval {
        let points = [start] + times.filter { $0 > start && $0 < end } + [end]
        return zip(points.dropFirst(), points).map { $0.timeIntervalSince($1) }.max() ?? 0
    }
}
