import XCTest
import MoneroKit
@testable import MoneroOne

/// Payment link format v2: the short link, its derivation and the spec's
/// test vector. Android checks its port against the same numbers.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Link format v2".
final class PaymentLinkV2Tests: XCTestCase {
    // Spec vector: secret 00 01 … 0f, height 150. k < l, so spend == k.
    private let vectorSecretHex = "000102030405060708090a0b0c0d0e0f"
    private let vectorHeight: UInt64 = 150
    /// The link as it was before the fragment directive; it still parses.
    private let vectorLink = "https://monero.one/c#2112drXXUifSrRnXLGbXg8E3b"
    /// New links: the body behind `:~:m1=`.
    private let vectorWebLink = "https://monero.one/c#2:~:m1=112drXXUifSrRnXLGbXg8E3b"
    /// The app-only links of test builds, removed: they no longer open.
    private let vectorAppLink = "https://monero.one/a#2112drXXUifSrRnXLGbXg8E3b"
    private let vectorSchemeLink = "moneroone://c#2112drXXUifSrRnXLGbXg8E3b"
    private let vectorK = "6a5bd15ceb3ca1dc24f7056feabfb1b825296bc5b26cfdcff8ad8362145ce908"
    private let vectorSpend = "6a5bd15ceb3ca1dc24f7056feabfb1b825296bc5b26cfdcff8ad8362145ce908"
    private let vectorAddress = "49brhubHMBe7enmsCDmGAJi63rX3uaGutSTf5afWoCeyDWsaXDhXwuN9WYB19H9dZeRGaYeZ74YpqX4qKGCMcyGP9bv31Hz"
    private let vectorId = "de4b02dc06db96f7"

    // Second vector: secret 01 02 … 10, height 3500000. k ≥ l, so the
    // reduction matters: spend != k.
    private let reducedSecretHex = "0102030405060708090a0b0c0d0e0f10"
    private let reducedHeight: UInt64 = 3_500_000
    private let reducedLink = "https://monero.one/c#2:~:m1=18DfbjXLth7APvt3qQPgtfJwRq"
    private let reducedK = "ade11baac32c1fd6a72d6050d89f2aaced5462acadae8a6967b62cfdd0229d10"
    private let reducedSpend = "c00d264da9c90c7ed19068adf9a54b97ed5462acadae8a6967b62cfdd0229d00"
    private let reducedAddress = "48vAo8XgJkBXtD3HqhVCvF9vpavqBuGK2WSPXTQSMeyXAy6xzEmgFHZiwkKYcnNv2fDsW9S31nnpHN6J3pMGrRiTR3NC7nL"
    private let reducedId = "a6e2ad8e98af4322"

    private func bytes(_ hex: String) throws -> [UInt8] {
        try XCTUnwrap([UInt8](hex: hex))
    }

    // MARK: - Vector

    func testVectorBuildsTheLink() throws {
        let link = try XCTUnwrap(EnvelopeLink(secret: bytes(vectorSecretHex), restoreHeight: vectorHeight))
        XCTAssertEqual(link.url, vectorWebLink)
        XCTAssertEqual(link.url.count, 52)
        XCTAssertEqual(link.id, vectorId)
        XCTAssertEqual(link.amount, 0)
        XCTAssertEqual(link.expiry, 0)
        XCTAssertNil(link.expiryDate)

        let reduced = try XCTUnwrap(EnvelopeLink(secret: bytes(reducedSecretHex), restoreHeight: reducedHeight))
        XCTAssertEqual(reduced.url, reducedLink)
        XCTAssertEqual(reduced.id, reducedId)
    }

    func testVectorParsesBack() throws {
        let link = try EnvelopeLink.parse(vectorLink)
        XCTAssertEqual(link.secret, try bytes(vectorSecretHex))
        XCTAssertEqual(link.restoreHeight, vectorHeight)
        XCTAssertEqual(link.id, vectorId)
        XCTAssertEqual(link, EnvelopeLink(secret: try bytes(vectorSecretHex), restoreHeight: vectorHeight))
        XCTAssertTrue(EnvelopeLink.looksLikeClaimLink(vectorLink))
        // Pasted without a scheme, with spaces around it.
        XCTAssertEqual(try EnvelopeLink.parse("  monero.one/c#2112drXXUifSrRnXLGbXg8E3b\n"), link)
        XCTAssertEqual(try EnvelopeLink.parse(reducedLink).restoreHeight, reducedHeight)
    }

    func testVectorKeysAndId() throws {
        let secret = try bytes(vectorSecretHex)
        XCTAssertEqual(EnvelopeV2.k(secret: secret).hexString, vectorK)
        XCTAssertEqual(EnvelopeV2.spendKey(secret: secret).hexString, vectorSpend)
        XCTAssertEqual(EnvelopeV2.id(secret: secret), vectorId)

        let reduced = try bytes(reducedSecretHex)
        XCTAssertEqual(EnvelopeV2.k(secret: reduced).hexString, reducedK)
        XCTAssertEqual(EnvelopeV2.spendKey(secret: reduced).hexString, reducedSpend)
        XCTAssertNotEqual(reducedK, reducedSpend)
        XCTAssertEqual(EnvelopeV2.id(secret: reduced), reducedId)

        // The words are the legacy words of the reduced key.
        XCTAssertEqual(EnvelopeV2.words(secret: reduced).flatMap(EnvelopeWords.decode)?.hexString, reducedSpend)
    }

    /// The address through the app's own restore path (`MoneroWallet.create`
    /// with the 25 words, as `EnvelopeRuntime` opens an envelope), not the
    /// envelope's own key math.
    @MainActor
    func testVectorAddressFromTheKitRestore() async throws {
        let link = try XCTUnwrap(EnvelopeLink(secret: bytes(vectorSecretHex), restoreHeight: vectorHeight))
        let kitAddress = try await restoredAddress(words: link.words)
        XCTAssertEqual(kitAddress, vectorAddress)
        XCTAssertEqual(EnvelopeSecret.address(for: link.words, networkType: .mainnet), vectorAddress)

        let reduced = try XCTUnwrap(EnvelopeLink(secret: bytes(reducedSecretHex), restoreHeight: reducedHeight))
        let reducedKitAddress = try await restoredAddress(words: reduced.words)
        XCTAssertEqual(reducedKitAddress, reducedAddress)
        XCTAssertEqual(EnvelopeSecret.address(for: reduced.words, networkType: .mainnet), reducedAddress)
    }

    /// wallet2 reduces what it restores and hashes the reduced spend key
    /// for the view key (account.cpp), so the words of an unreduced k open
    /// the same wallet. The app's own address check takes canonical keys
    /// only, so the app never makes or accepts such words.
    @MainActor
    func testUnreducedKWordsOpenTheSameWalletInWallet2() async throws {
        let k = EnvelopeV2.k(secret: try bytes(reducedSecretHex))
        let unreducedWords = try XCTUnwrap(EnvelopeWords.encode(k))
        let address = try await restoredAddress(words: unreducedWords)
        XCTAssertEqual(address, reducedAddress)
        XCTAssertNil(EnvelopeSecret.address(for: unreducedWords, networkType: .mainnet))
    }

    // MARK: - Parse errors

    func testBadShortLinksAreIncomplete() {
        let body = String(vectorLink.dropFirst("https://monero.one/c#2".count))
        let secret = String(body.prefix(22))
        // [String] with String parts only: Xcode 26 (CI) times out type
        // checking this literal when it mixes String and Substring.
        let cases: [String] = [
            // No height after the 22 secret characters.
            "https://monero.one/c#2" + secret,
            // A character outside the alphabet (0, O, I, l).
            vectorLink.replacingOccurrences(of: "112d", with: "102d"),
            vectorLink.replacingOccurrences(of: "rXX", with: "rOX"),
            vectorLink + "l",
            // A secret of 2^128 or more.
            "https://monero.one/c#2" + String(repeating: "z", count: 22) + "1",
            // A height longer than 11 characters, or past UInt64.max.
            "https://monero.one/c#2" + secret + String(repeating: "2", count: 12),
            "https://monero.one/c#2" + secret + "zzzzzzzzzzz",
            "https://monero.one/c#2",
            "https://monero.one/c#-",
            "https://monero.one/c#",
        ]
        for link in cases {
            XCTAssertThrowsError(try EnvelopeLink.parse(link), link) {
                XCTAssertEqual($0 as? EnvelopeLink.ParseError, .incomplete, link)
            }
        }
    }

    func testUnknownShortVersionAsksForUpdate() {
        for version in ["3", "a", "Z"] {
            let link = vectorLink.replacingOccurrences(of: "c#2", with: "c#\(version)")
            XCTAssertThrowsError(try EnvelopeLink.parse(link)) {
                XCTAssertEqual($0 as? EnvelopeLink.ParseError, .unsupportedVersion, link)
            }
        }
    }

    func testRejectsHttp() {
        let http = vectorLink.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(http))
        XCTAssertThrowsError(try EnvelopeLink.parse(http)) { XCTAssertEqual($0 as? EnvelopeLink.ParseError, .notClaimLink) }
    }

    func testV1LinksStillParse() throws {
        let v1 = "https://monero.one/c#v=1&s=cogs-aloof-wobbly-island-zigzags-setup-saxophone-jockey-request-wise-mighty-border-different-axes-innocent-subtly-northern-testing-fidget-lids-absorb-benches-madness-nocturnal-aloof&h=150&a=100000000000&e=1791000000&n=0123456789abcdef"
        let link = try EnvelopeLink.parse(v1)
        XCTAssertEqual(link.format, .v1)
        XCTAssertNil(link.secret)
        XCTAssertEqual(link.url, v1)
        XCTAssertEqual(link.id, "0123456789abcdef")
    }

    // MARK: - Base58 integers

    func testBase58Integers() throws {
        XCTAssertEqual(Base58Integer.encode(0), "1")
        XCTAssertEqual(Base58Integer.encode(57), "z")
        XCTAssertEqual(Base58Integer.encode(58), "21")
        XCTAssertEqual(Base58Integer.encode(150), "3b")
        XCTAssertEqual(Base58Integer.encode(UInt64.max), "jpXCZedGfVQ")
        XCTAssertEqual(Base58Integer.decodeUInt64("jpXCZedGfVQ"), UInt64.max)
        XCTAssertNil(Base58Integer.decodeUInt64("jpXCZedGfVR"))
        XCTAssertEqual(Base58Integer.decodeUInt64("1113b"), 150)
        XCTAssertNil(Base58Integer.decodeUInt64(""))
        XCTAssertNil(Base58Integer.decodeUInt64("0"))

        XCTAssertEqual(Base58Integer.encode(bigEndian: [UInt8](repeating: 0, count: 16), width: 22), String(repeating: "1", count: 22))
        XCTAssertEqual(Base58Integer.encode(bigEndian: [UInt8](repeating: 0xff, count: 16), width: 22), "YcVfxkQb6JRzqk5kF2tNLv")
        XCTAssertNil(Base58Integer.encode(bigEndian: [UInt8](repeating: 0xff, count: 16), width: 21))
        // Round trip through random secrets.
        for _ in 0..<200 {
            let secret = try XCTUnwrap(EnvelopeV2.newSecret())
            let text = try XCTUnwrap(Base58Integer.encode(bigEndian: secret, width: 22))
            XCTAssertEqual(text.count, 22)
            XCTAssertEqual(Base58Integer.decode(Substring(text), byteCount: 16), secret)
        }
    }

    // MARK: - New links

    func testNewLinksAreShortV2() throws {
        let secret = try EnvelopeSecret.generate(networkType: .mainnet)
        let link = try XCTUnwrap(EnvelopeLink(secret: secret.linkSecret, restoreHeight: 3_512_345))
        XCTAssertEqual(link.words, secret.words)
        XCTAssertLessThanOrEqual(link.url.count, 54)
        XCTAssertEqual(try EnvelopeLink.parse(link.url), link)
        XCTAssertEqual(EnvelopeSecret.address(for: link.words, networkType: .mainnet), secret.address)
    }

    @MainActor
    func testRecordKeepsTheV2SecretOnly() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        let link = try XCTUnwrap(EnvelopeLink(secret: bytes(vectorSecretHex), restoreHeight: vectorHeight))
        var record = EnvelopeRecord(id: link.id, role: .received, words: nil, address: "addr", restoreHeight: link.restoreHeight,
                                    amount: 0, expiry: 0, createdAt: Date(), status: .created)
        record.setSecret(from: link)
        XCTAssertNil(record.words)
        XCTAssertEqual(record.secret, vectorSecretHex)
        XCTAssertEqual(record.link, link)
        XCTAssertNil(record.expiryDate)
        XCTAssertNil(record.knownAmount)
        XCTAssertFalse(record.isExpired(now: Date()))
        try store.save(record)
        XCTAssertEqual(EnvelopeStore(service: service).record(id: link.id, role: .received)?.link?.url, vectorWebLink)

        record.lastBalance = 501_000_000_000
        XCTAssertEqual(record.knownAmount, 501_000_000_000)
        record.forgetSecret()
        XCTAssertNil(record.link)
        store.removeAll()
    }

    func testDiagnosticLogRedactsShortLinks() {
        XCTAssertEqual(EnvelopeLink.redacted(in: "open \(vectorLink) now"), "open https://monero.one/c#<redacted> now")
        XCTAssertEqual(EnvelopeLink.redacted(in: "open \(vectorWebLink) now"), "open https://monero.one/c#<redacted> now")
        XCTAssertEqual(EnvelopeLink.redacted(in: "open \(vectorAppLink) now"), "open https://monero.one/a#<redacted> now")
        XCTAssertEqual(EnvelopeLink.redacted(in: "open \(vectorSchemeLink) now"), "open moneroone://c#<redacted> now")
        XCTAssertEqual(EnvelopeLink.redacted(in: "MoneroOne://C#2abc"), "MoneroOne://C#<redacted>")
    }

    // MARK: - Link privacy

    /// A web page that opens the link sees only `#2`: the secret and the
    /// height sit behind the fragment directive.
    func testWebLinkKeepsTheSecretBehindTheDirective() throws {
        for _ in 0..<20 {
            let secret = try XCTUnwrap(EnvelopeV2.newSecret())
            let link = try XCTUnwrap(EnvelopeLink(secret: secret, restoreHeight: UInt64.random(in: 0...4_000_000)))
            let parts = link.url.components(separatedBy: ":~:")
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0], "https://monero.one/c#2")
            let body = try XCTUnwrap(EnvelopeV2.fragment(secret: secret, restoreHeight: link.restoreHeight)).dropFirst()
            XCTAssertEqual(parts[1], "m1=" + body)
            XCTAssertFalse(parts[0].contains(body.prefix(EnvelopeV2.secretLength)))
        }
    }

    /// Every shape opens the same link: the new web link and the old one,
    /// each without a scheme or inside a sentence.
    func testEveryLinkShapeParses() throws {
        let link = try XCTUnwrap(EnvelopeLink(secret: bytes(vectorSecretHex), restoreHeight: vectorHeight))
        let shapes = [
            vectorWebLink,
            vectorLink,
            "monero.one/c#2:~:m1=112drXXUifSrRnXLGbXg8E3b",
            "monero.one/c/#2:~:m1=112drXXUifSrRnXLGbXg8E3b",
            "monero.one/c#2112drXXUifSrRnXLGbXg8E3b",
            // An app that percent-encodes the directive.
            "https://monero.one/c#2%3A~%3Am1=112drXXUifSrRnXLGbXg8E3b",
            "https://monero.one/c#2%3A%7E%3Am1=112drXXUifSrRnXLGbXg8E3b",
            // Another directive next to ours.
            "https://monero.one/c#2:~:text=hi&m1=112drXXUifSrRnXLGbXg8E3b",
            // A chat app that takes the sentence's punctuation into the link.
            vectorWebLink + ".",
            vectorLink + ",",
            vectorWebLink + ";",
            vectorLink + "!",
            vectorLink + "?",
            vectorWebLink + ")",
            vectorWebLink + ".)",
            "  \(vectorWebLink)\n",
        ]
        for shape in shapes {
            XCTAssertTrue(EnvelopeLink.looksLikeClaimLink(shape), shape)
            XCTAssertEqual(try EnvelopeLink.parse(shape), link, shape)
        }
    }

    func testBadDirectiveLinks() {
        let incomplete = [
            "https://monero.one/c#2:~:",
            "https://monero.one/c#2:~:m1=",
            "https://monero.one/c#2:~:text=hi",
            "https://monero.one/c#:~:m1=112drXXUifSrRnXLGbXg8E3b",
            // The secret with no height.
            "https://monero.one/c#2:~:m1=112drXXUifSrRnXLGbXg8E",
            "https://monero.one/c#2:~:m1=102drXXUifSrRnXLGbXg8E3b",
        ]
        for link in incomplete {
            XCTAssertThrowsError(try EnvelopeLink.parse(link), link) {
                XCTAssertEqual($0 as? EnvelopeLink.ParseError, .incomplete, link)
            }
        }
        XCTAssertThrowsError(try EnvelopeLink.parse("https://monero.one/c#3:~:m1=112drXXUifSrRnXLGbXg8E3b")) {
            XCTAssertEqual($0 as? EnvelopeLink.ParseError, .unsupportedVersion)
        }
        // Only `monero.one/c` links are claim links; `http` is not. The
        // app-only links of test builds (`/a`, `moneroone://c`) no longer
        // open.
        for other in [vectorAppLink, vectorSchemeLink, "monero.one/a#2112drXXUifSrRnXLGbXg8E3b",
                      "MONEROONE://c#2112drXXUifSrRnXLGbXg8E3b", "moneroone://c#2", "moneroone://price",
                      "http://monero.one/c#2112drXXUifSrRnXLGbXg8E3b",
                      "https://monero.one/b#2112drXXUifSrRnXLGbXg8E3b", "https://evil.one/c#2112drXXUifSrRnXLGbXg8E3b"] {
            XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(other), other)
        }
    }

    /// Messages, Mail and Notes make a link tappable with the system's link
    /// detector. It must find the whole link in the share sentence.
    @MainActor
    func testLinkDetectorFindsTheLinkInTheShareText() throws {
        let link = try XCTUnwrap(EnvelopeLink(secret: bytes(vectorSecretHex), restoreHeight: vectorHeight))
        var record = EnvelopeRecord(id: link.id, role: .sent, words: nil, address: "addr", restoreHeight: link.restoreHeight,
                                    amount: 1_000_000_000, expiry: 0, createdAt: Date(), status: .pending)
        record.setSecret(from: link)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let text = try XCTUnwrap(PaymentLinkFunder.shareText(for: record))
        let urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
        XCTAssertTrue(urls.contains(URL(string: link.url)!), "\(urls)")
    }

    // MARK: - Helpers

    /// Restores `words` with the app's wallet path, reads the address and
    /// deletes the files. The node is unreachable on purpose: the restore
    /// is offline.
    @MainActor
    private func restoredAddress(words: [String]) async throws -> String {
        let cacheId = "envelopes/kittest-\(UUID().uuidString.prefix(8).lowercased())"
        let wallet = MoneroWallet()
        try await wallet.create(
            seed: words,
            restoreHeight: 0,
            node: MoneroKit.Node(url: URL(string: "http://localhost:9")!, isTrusted: false),
            networkType: .mainnet,
            cacheIdOverride: cacheId
        )
        var address = ""
        for _ in 0..<150 where address.isEmpty {
            address = wallet.primaryAddress
            if address.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        }
        await wallet.stopAsync()
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoneroKit", isDirectory: true)
            .appendingPathComponent(cacheId, isDirectory: true) {
            try? FileManager.default.removeItem(at: dir)
        }
        return try XCTUnwrap(address.isEmpty ? nil : address, "the kit gave no address")
    }
}
