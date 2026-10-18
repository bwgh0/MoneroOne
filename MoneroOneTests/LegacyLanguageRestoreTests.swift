import HsToolKit
import MoneroKit
import XCTest
@testable import MoneroOne

/// The whole 25-word restore chain in every wallet2 language, inside the app
/// process: paste parsing, `SeedPhraseValidator`, the kit handoff
/// (`MoneroWallet.kitCredentials`) and a real wallet2 restore. The phrases
/// and the oracle addresses are `legacy-vectors.json`, shared with the
/// Android suite (app/src/test/resources) and the kit's
/// LegacyLanguageAddressTests. Spanish, German, Japanese and Russian failed
/// here until the kit handed wallet2 NFC instead of NFKD.
final class LegacyLanguageRestoreTests: XCTestCase {

    struct Fixture: Decodable {
        let lang: String
        let source: String
        let phrase: String
        let address: String

        var words: [String] { phrase.split(separator: " ").map(String.init) }
    }

    static let vectors: [Fixture] = {
        guard let url = Bundle(for: LegacyLanguageRestoreTests.self).url(forResource: "legacy-vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Fixture].self, from: data)) ?? []
    }()

    static func vector(_ lang: String, source: String = "oracle") throws -> Fixture {
        try XCTUnwrap(vectors.first { $0.lang == lang && $0.source == source }, "no \(source) vector for \(lang)")
    }

    /// ‘ ’ ‛ ʼ: what notes apps, word processors and some keyboards put in
    /// place of "'".
    static let typographicApostrophes: [Character] = ["\u{2018}", "\u{2019}", "\u{201B}", "\u{02BC}"]

    // MARK: - Every wallet2 language

    func testEveryLanguageRestoresThroughTheEntryChain() async throws {
        XCTAssertEqual(Set(Self.vectors.map(\.lang)).count, 13, "legacy-vectors.json is missing from the test bundle")
        for fixture in Self.vectors {
            let name = "\(fixture.lang) (\(fixture.source))"
            // A paste lower-cases, so German capitals come back from the
            // validator, not from the text.
            let tokens = SeedPasteParser.parse(fixture.phrase)
            guard case .valid(let phrase) = SeedPhraseValidator.validate(tokens, format: .legacy) else {
                XCTFail("\(name): the validator rejected the phrase")
                continue
            }
            XCTAssertEqual(SeedWordlists.legacy[phrase.language].englishName, fixture.lang)
            XCTAssertEqual(phrase.words, fixture.words, name)

            let address = try await restoredAddress(MoneroWallet.kitCredentials(for: phrase.words))
            XCTAssertEqual(address, fixture.address, name)
        }
    }

    // MARK: - Case at the handoff

    /// The old free-text restore stored lower-cased words. wallet2 alone
    /// cannot read "ästhetik": its `towlower` maps ASCII only. The handoff
    /// passes the list form; the stored words stay as they are. The German
    /// vector holds all five Ä/Ö/Ü words of the list.
    func testStoredLowercaseGermanSeedRestoresThroughTheHandoff() async throws {
        let german = try Self.vector("German")
        let stored = german.words.map { $0.lowercased() }
        XCTAssertTrue(["ästhetik", "ökologie", "ölberg", "ölkrise", "übermut"].allSatisfy(stored.contains))

        let raw = try await restoredAddress(.legacy(seed: stored, passphrase: ""))
        XCTAssertEqual(raw, "", "wallet2 in this process now matches Ä/Ö/Ü case-insensitively")

        let credentials = MoneroWallet.kitCredentials(for: stored)
        guard case .legacy(let words, _) = credentials else {
            return XCTFail("25 words must stay legacy")
        }
        XCTAssertEqual(words, german.words)
        let address = try await restoredAddress(credentials)
        XCTAssertEqual(address, german.address)
    }

    func testHandoffLeavesOtherWordsAsTheyAre() throws {
        let polyseed = SeedPasteParser.parse("raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy airport language")
        guard case .polyseed(let p, _) = MoneroWallet.kitCredentials(for: polyseed) else { return XCTFail("16 words") }
        XCTAssertEqual(p, polyseed)

        let bip39 = Array(repeating: "abandon", count: 23) + ["art"]
        guard case .bip39(let b, _) = MoneroWallet.kitCredentials(for: bip39) else { return XCTFail("24 words") }
        XCTAssertEqual(b, bip39)

        let english = try Self.vector("English").words
        guard case .legacy(let e, _) = MoneroWallet.kitCredentials(for: english) else { return XCTFail("25 words") }
        XCTAssertEqual(e, english)

        // A phrase the validator rejects reaches wallet2 unchanged, which
        // reports its own error.
        let junk = Array(repeating: "zzzz", count: 25)
        guard case .legacy(let j, _) = MoneroWallet.kitCredentials(for: junk) else { return XCTFail("25 words") }
        XCTAssertEqual(j, junk)
    }

    // MARK: - Lojban apostrophes

    func testLojbanApostrophesSurvivePaste() throws {
        let lojban = try Self.vector("Lojban")
        XCTAssertGreaterThanOrEqual(lojban.words.filter { $0.contains("'") }.count, 3)

        let numbered = lojban.words.enumerated()
            .map { "\($0.offset + 1). \"\($0.element)\"" }
            .joined(separator: "\n")
        XCTAssertEqual(SeedPasteParser.parse(numbered), lojban.words)

        // A document or notes app turns "'" into one of these.
        for apostrophe in Self.typographicApostrophes {
            let name = "U+" + String(apostrophe.unicodeScalars.first!.value, radix: 16, uppercase: true)
            let curly = lojban.phrase.replacingOccurrences(of: "'", with: String(apostrophe))
            XCTAssertEqual(SeedPasteParser.parse(curly), lojban.words, name)
            guard case .valid(let phrase) = SeedPhraseValidator.validate(SeedPasteParser.parse(curly), format: .legacy) else {
                XCTFail("\(name): the validator rejected the phrase")
                continue
            }
            XCTAssertEqual(phrase.words, lojban.words, name)

            // Each word quoted with the same mark: the quotes go, the inner
            // apostrophes stay.
            let quoted = lojban.words
                .map { "\(apostrophe)\($0.replacingOccurrences(of: "'", with: String(apostrophe)))\(apostrophe)" }
                .joined(separator: " ")
            XCTAssertEqual(SeedPasteParser.parse(quoted), lojban.words, name)
        }
    }

    func testLojbanApostrophesSurviveTyping() throws {
        let lojban = try Self.vector("Lojban")
        for word in lojban.words where word.contains("'") {
            XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit(word, format: .legacy, committed: []), word)
            for apostrophe in Self.typographicApostrophes {
                let curly = word.replacingOccurrences(of: "'", with: String(apostrophe))
                XCTAssertEqual(SeedPhraseValidator.canonicalOnCommit(curly, format: .legacy, committed: []), word, curly)
            }
        }
        XCTAssertEqual(SeedWordTextField(frame: .zero).smartQuotesType, .no)
    }

    // MARK: - Helpers

    /// Restores `credentials` with the kit (no daemon connection) and returns
    /// the primary address, or "" when wallet2 refuses the seed.
    private func restoredAddress(_ credentials: MoneroKit.MoneroWallet) async throws -> String {
        let walletId = "legacy-language-test-\(UUID().uuidString)"
        defer {
            if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("MoneroKit/\(walletId)"))
            }
        }
        let kit = try MoneroKit.Kit(
            wallet: credentials,
            account: 0,
            restoreHeight: 0,
            walletId: walletId,
            node: MoneroKit.Node(url: URL(string: "https://node.monero.one:443")!, isTrusted: false),
            networkType: .mainnet,
            reachabilityManager: ReachabilityManager(),
            logger: nil,
            moneroCoreLogLevel: 0
        )
        await kit.prepareOnly()
        let address = kit.runtimePrimaryAddress
        await kit.stopAsync()
        return address
    }
}
