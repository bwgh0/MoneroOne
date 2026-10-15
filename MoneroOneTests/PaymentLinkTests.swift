import XCTest
import UIKit
import LinkPresentation
import MoneroKit
@testable import MoneroOne

/// Payment links: link format (spec vector), secret derivation, status
/// rules, storage and log redaction. Spec: docs/2026-10-03-payment-links-spec.md.
final class PaymentLinkTests: XCTestCase {
    private let vectorWords = "cogs aloof wobbly island zigzags setup saxophone jockey request wise mighty border different axes innocent subtly northern testing fidget lids absorb benches madness nocturnal aloof"
        .split(separator: " ").map(String.init)
    private let vectorLink = "https://monero.one/c#v=1&s=cogs-aloof-wobbly-island-zigzags-setup-saxophone-jockey-request-wise-mighty-border-different-axes-innocent-subtly-northern-testing-fidget-lids-absorb-benches-madness-nocturnal-aloof&h=150&a=100000000000&e=1791000000&n=0123456789abcdef"
    private let vectorAddress = "48F34bwGALB8apPAXnwgA916e53fKJPs2eXoJrdG53LeWzNTQT1ASJSNKpvqmQ6kw2i5hALMdWYKCeAJpwDSMdTFG7ynvk4"
    private let vectorSpendKey = "377deef003a763c55f958044558a1c96c7fd6455092be243e983ee835b02d30f"

    private var vector: EnvelopeLink {
        EnvelopeLink(words: vectorWords, restoreHeight: 150, amount: 100_000_000_000, expiry: 1_791_000_000, id: "0123456789abcdef")
    }

    // MARK: - Link format

    func testBuildsSpecVector() {
        XCTAssertEqual(vector.url, vectorLink)
    }

    func testParsesSpecVector() throws {
        XCTAssertEqual(try EnvelopeLink.parse(vectorLink), vector)
        XCTAssertTrue(EnvelopeLink.looksLikeClaimLink(vectorLink))
    }

    func testParsesWithoutScheme() throws {
        let bare = String(vectorLink.dropFirst("https://".count))
        XCTAssertEqual(try EnvelopeLink.parse(bare), vector)
        XCTAssertEqual(try EnvelopeLink.parse("  \(vectorLink)\n"), vector)
    }

    func testRejectsHttpAndOtherHosts() {
        let http = vectorLink.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(http))
        XCTAssertThrowsError(try EnvelopeLink.parse(http)) { XCTAssertEqual($0 as? EnvelopeLink.ParseError, .notClaimLink) }
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(vectorLink.replacingOccurrences(of: "monero.one", with: "evil.one")))
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(vectorLink.replacingOccurrences(of: "/c#", with: "/x#")))
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink(vectorAddress))
        XCTAssertFalse(EnvelopeLink.looksLikeClaimLink("monero:\(vectorAddress)?tx_amount=1"))
    }

    func testParsesWordsLeniently() throws {
        let words = vectorWords.joined(separator: "-")
        for separator in ["+", "%20", " "] {
            let link = vectorLink.replacingOccurrences(of: words, with: vectorWords.joined(separator: separator))
            XCTAssertEqual(try EnvelopeLink.parse(link).words, vectorWords, "separator \(separator)")
        }
        XCTAssertEqual(try EnvelopeLink.parse(vectorLink.replacingOccurrences(of: words, with: words.uppercased())).words, vectorWords)
    }

    func testIgnoresUnknownKeysAndOrder() throws {
        let link = "https://monero.one/c#n=0123456789abcdef&x=9&e=1791000000&a=100000000000&h=150&s=\(vectorWords.joined(separator: "-"))&v=1&utm=chat"
        XCTAssertEqual(try EnvelopeLink.parse(link), vector)
    }

    func testOtherVersionAsksForUpdate() {
        let v2 = vectorLink.replacingOccurrences(of: "v=1", with: "v=2")
        XCTAssertThrowsError(try EnvelopeLink.parse(v2)) { XCTAssertEqual($0 as? EnvelopeLink.ParseError, .unsupportedVersion) }
        XCTAssertEqual(EnvelopeLink.ParseError.unsupportedVersion.message, "Update Monero One to open this link.")
    }

    func testMissingOrBadKeysAreIncomplete() {
        let cases = [
            vectorLink.replacingOccurrences(of: "v=1&", with: ""),
            vectorLink.replacingOccurrences(of: "&h=150", with: ""),
            vectorLink.replacingOccurrences(of: "&a=100000000000", with: ""),
            vectorLink.replacingOccurrences(of: "&e=1791000000", with: ""),
            vectorLink.replacingOccurrences(of: "&n=0123456789abcdef", with: ""),
            vectorLink.replacingOccurrences(of: "n=0123456789abcdef", with: "n=0123456789abcde"),
            vectorLink.replacingOccurrences(of: "n=0123456789abcdef", with: "n=0123456789abcdeg"),
            vectorLink.replacingOccurrences(of: "h=150", with: "h=-1"),
            vectorLink.replacingOccurrences(of: "a=100000000000", with: "a=1.5"),
            vectorLink.replacingOccurrences(of: "-aloof&h", with: "&h"),
            "https://monero.one/c#",
        ]
        for link in cases {
            XCTAssertThrowsError(try EnvelopeLink.parse(link), link) {
                XCTAssertEqual($0 as? EnvelopeLink.ParseError, .incomplete, link)
            }
        }
        XCTAssertEqual(EnvelopeLink.ParseError.incomplete.message, "This link is not complete.")
    }

    func testNewIdIsSixteenLowercaseHex() {
        let a = EnvelopeLink.newId()
        XCTAssertTrue(EnvelopeLink.isEnvelopeId(a))
        XCTAssertNotEqual(a, EnvelopeLink.newId())
        XCTAssertFalse(EnvelopeLink.isEnvelopeId("0123456789ABCDEF"))
    }

    // MARK: - Secret

    func testVectorWordsRestoreToVectorAddressAndKey() throws {
        XCTAssertEqual(EnvelopeSecret.spendKeyHex(for: vectorWords), vectorSpendKey)
        XCTAssertEqual(EnvelopeSecret.address(for: vectorWords, networkType: .mainnet), vectorAddress)
        XCTAssertNoThrow(try EnvelopeSecret.verify(words: vectorWords, address: vectorAddress, networkType: .mainnet))
        // wallet2 agrees that both keys belong to the vector address.
        let spend = try XCTUnwrap(EnvelopeWords.decode(vectorWords))
        XCTAssertTrue(MoneroKit.Kit.isValid(address: vectorAddress, networkType: .mainnet))
        XCTAssertTrue(MoneroKit.Kit.isValid(viewKey: spend.hexString, address: vectorAddress, isViewKey: false, networkType: .mainnet))
        XCTAssertTrue(MoneroKit.Kit.isValid(viewKey: EnvelopeCrypto.viewKey(spendKey: spend).hexString, address: vectorAddress, isViewKey: true, networkType: .mainnet))
        // wallet2 really checks: a wrong key for this address fails.
        var wrong = spend
        wrong[0] ^= 1
        XCTAssertFalse(MoneroKit.Kit.isValid(viewKey: EnvelopeCrypto.reduce(wrong).hexString, address: vectorAddress, isViewKey: false, networkType: .mainnet))
        XCTAssertFalse(MoneroKit.Kit.isValid(viewKey: spend.hexString, address: vectorAddress, isViewKey: true, networkType: .mainnet))
    }

    func testSpendKeyGivesVectorWords() throws {
        let spend = try XCTUnwrap(hexBytes(vectorSpendKey))
        XCTAssertEqual(EnvelopeWords.encode(spend), vectorWords)
        XCTAssertNil(EnvelopeWords.encode([1, 2, 3]))
    }

    func testDecodeRejectsBadChecksumAndUnknownWords() {
        var badChecksum = vectorWords
        badChecksum[24] = "zoom"
        XCTAssertNil(EnvelopeWords.decode(badChecksum))
        var unknown = vectorWords
        unknown[3] = "qqqq"
        XCTAssertNil(EnvelopeWords.decode(unknown))
        XCTAssertNil(EnvelopeWords.decode(Array(vectorWords.dropLast())))
        // wallet2 matches English words on their first 3 letters.
        var prefixes = vectorWords
        prefixes[0] = "cogz"
        XCTAssertEqual(EnvelopeWords.decode(prefixes)?.hexString, vectorSpendKey)
    }

    func testBase58AndCrc32() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(MoneroBase58.encode([]), "")
        XCTAssertEqual(MoneroBase58.encode([0x00]), "11")
        XCTAssertEqual(MoneroBase58.encode([0xff]), "5Q")
        XCTAssertEqual(MoneroBase58.encode([0, 0, 0, 0, 0, 0, 0, 0]), "11111111111")
    }

    func testVerifyRejectsMismatch() {
        let other = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
        XCTAssertThrowsError(try EnvelopeSecret.verify(words: vectorWords, address: other, networkType: .mainnet))
        XCTAssertThrowsError(try EnvelopeSecret.verify(words: vectorWords, address: NullKeyAddress.mainnet, networkType: .mainnet))
        XCTAssertThrowsError(try EnvelopeSecret.verify(words: Array(vectorWords.dropLast()), address: vectorAddress, networkType: .mainnet))
        XCTAssertThrowsError(try EnvelopeSecret.verify(words: vectorWords, address: vectorAddress, networkType: .testnet))
    }

    private func hexBytes(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    func testGeneratesRandomVerifiedSecrets() throws {
        let a = try EnvelopeSecret.generate(networkType: .mainnet)
        let b = try EnvelopeSecret.generate(networkType: .mainnet)
        XCTAssertEqual(a.words.count, 25)
        XCTAssertNotEqual(a.words, b.words)
        XCTAssertNotEqual(a.address, b.address)
        XCTAssertFalse(NullKeyAddress.isNullKey(a.address))
        XCTAssertNoThrow(try EnvelopeSecret.verify(words: a.words, address: a.address, networkType: .mainnet))
        XCTAssertEqual(EnvelopeSecret.address(for: a.words, networkType: .mainnet), a.address)
    }

    // MARK: - Status rules

    private func obs(seen: Bool = true, conf: Int = 0, balance: UInt64 = 0, unlocked: UInt64 = 0, spends: [String] = []) -> EnvelopeObservation {
        EnvelopeObservation(fundingSeen: seen, fundingConfirmations: conf, balance: balance, unlockedBalance: unlocked, spendTxids: spends)
    }

    func testStatusTable() {
        let rules = EnvelopeStatusRules.self
        XCTAssertEqual(rules.status(for: .empty, reclaimTxid: nil), .notFunded)
        // In the pool: seen, no balance yet.
        XCTAssertEqual(rules.status(for: obs(conf: 0), reclaimTxid: nil), .pending)
        XCTAssertEqual(rules.status(for: obs(conf: 3, balance: 5), reclaimTxid: nil), .pending)
        XCTAssertEqual(rules.status(for: obs(conf: 10, balance: 5, unlocked: 5), reclaimTxid: nil), .ready)
        // Balance gone with a spend on chain: claimed.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"]), reclaimTxid: nil), .claimed)
        // Balance zero, no spend seen: not claimed yet (pool or stale read).
        XCTAssertEqual(rules.status(for: obs(conf: 12), reclaimTxid: nil), .pending)
        // Our reclaim.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["ours"]), reclaimTxid: "ours"), .reclaimed)
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 5, unlocked: 5), reclaimTxid: "ours"), .reclaimed)
        // Still in the pool a few minutes after it went out: reclaimed.
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 5, unlocked: 5), reclaimTxid: "ours", reclaimAge: 300), .reclaimed)
        // Unseen long after, money still there: the reclaim dropped.
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 5, unlocked: 5), reclaimTxid: "ours", reclaimAge: 3600), .ready)
        // Long after and seen: still reclaimed.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["ours"]), reclaimTxid: "ours", reclaimAge: 3600), .reclaimed)
        // A claim won the race against our reclaim.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"]), reclaimTxid: "ours"), .claimed)
    }

    func testExpiredIsALabelOverPendingAndReady() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(EnvelopeStatusRules.isExpired(.ready, expiry: 1_000, now: now))
        XCTAssertTrue(EnvelopeStatusRules.isExpired(.pending, expiry: 1_000, now: now))
        XCTAssertFalse(EnvelopeStatusRules.isExpired(.ready, expiry: 3_000, now: now))
        XCTAssertFalse(EnvelopeStatusRules.isExpired(.claimed, expiry: 1_000, now: now))
        XCTAssertFalse(EnvelopeStatusRules.isExpired(.notFunded, expiry: 1_000, now: now))
    }

    func testMinutesUntilReady() {
        XCTAssertEqual(EnvelopeStatusRules.minutesUntilReady(confirmations: 0), 20)
        XCTAssertEqual(EnvelopeStatusRules.minutesUntilReady(confirmations: 7), 6)
        XCTAssertEqual(EnvelopeStatusRules.minutesUntilReady(confirmations: 14), 0)
    }

    func testObservationFromHistory() {
        func tx(_ id: String, _ type: MoneroTransaction.TransactionType, height: UInt64?, status: MoneroTransaction.TransactionStatus = .confirmed,
                amount: String = "1", fee: String = "0") -> MoneroTransaction {
            MoneroTransaction(id: id, type: type, amount: Decimal(string: amount)!, fee: Decimal(string: fee)!, address: "", timestamp: Date(), confirmations: nil,
                              status: status, memo: nil, blockHeight: height)
        }
        let pool = EnvelopeRuntime.observation(transactions: [tx("f", .incoming, height: nil, status: .pending)], balance: 0, unlocked: 0, daemonHeight: 200)
        XCTAssertEqual(pool, obs(conf: 0))

        let mined = EnvelopeRuntime.observation(
            transactions: [tx("f", .incoming, height: 190), tx("c", .outgoing, height: 199, amount: "0.4", fee: "0.1"), tx("x", .outgoing, height: nil, status: .failed)],
            balance: Decimal(string: "0.5")!, unlocked: Decimal(string: "0.5")!, daemonHeight: 200
        )
        var expected = obs(conf: 10, balance: 500_000_000_000, unlocked: 500_000_000_000, spends: ["c"])
        expected.fundingHeight = 190
        XCTAssertEqual(mined, expected)

        // Reopened from its cache, the kit still stores the balance from
        // before the claim: the history caps it at zero.
        let stale = EnvelopeRuntime.observation(
            transactions: [tx("f", .incoming, height: 280, amount: "0.5018432", fee: "0.0018084"),
                           tx("c", .outgoing, height: 291, amount: "0.5000348", fee: "0.0018084")],
            balance: Decimal(string: "0.5018432")!, unlocked: Decimal(string: "0.5018432")!, daemonHeight: 301
        )
        XCTAssertEqual(stale.balance, 0)
        XCTAssertEqual(stale.unlockedBalance, 0)
        XCTAssertEqual(EnvelopeStatusRules.status(for: stale, reclaimTxid: nil), .claimed)
    }

    func testClaimFeeReserveUsesWallet2PriorityTwo() {
        // Android sweeps claims at wallet2 Priority_Medium (2); the reserve
        // must cover that, whatever the app's send default is.
        XCTAssertEqual(PaymentLinkFunder.claimFeePriority, .medium)
        XCTAssertEqual(PaymentLinkFunder.claimFeePriority.rawValue, 2)
    }

    func testAtomicConversion() {
        XCTAssertEqual(EnvelopeRuntime.piconero(Decimal(string: "0.5")!), 500_000_000_000)
        XCTAssertEqual(EnvelopeRuntime.piconero(Decimal(string: "0.000000000001")!), 1)
        XCTAssertEqual(EnvelopeRuntime.xmr(100_000_000_000), Decimal(string: "0.1")!)
        XCTAssertEqual(EnvelopeRuntime.piconero(-1), 0)
    }

    // MARK: - Storage

    @MainActor
    func testStoreRoundTripsInItsOwnKeychainService() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        let record = EnvelopeRecord(id: "0123456789abcdef", role: .sent, words: vectorWords, address: vectorAddress,
                                    restoreHeight: 150, amount: 100_000_000_000, expiry: 1_791_000_000,
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .created)
        try store.save(record)
        var updated = record
        updated.status = .pending
        updated.fundingTxid = "abc"
        try store.save(updated)

        let reloaded = EnvelopeStore(service: service)
        XCTAssertEqual(reloaded.records, [updated])
        XCTAssertEqual(reloaded.record(id: record.id, role: .sent)?.link, vector)
        XCTAssertNil(reloaded.record(id: record.id, role: .received))

        reloaded.remove(updated)
        XCTAssertTrue(EnvelopeStore(service: service).records.isEmpty)
    }

    @MainActor
    func testRemoveAllWipesEveryRecordAndSecret() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        let sent = EnvelopeRecord(id: "0123456789abcdef", role: .sent, words: vectorWords, address: vectorAddress,
                                  restoreHeight: 150, amount: 100_000_000_000, expiry: 1_791_000_000,
                                  createdAt: Date(), status: .ready)
        let received = EnvelopeRecord(id: "fedcba9876543210", role: .received, words: vectorWords, address: vectorAddress,
                                  restoreHeight: 150, amount: 1, expiry: 1_791_000_000, createdAt: Date(), status: .created)
        try store.save(sent)
        try store.save(received)
        XCTAssertTrue(store.hasUnsettledSentLinks)

        store.removeAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.hasUnsettledSentLinks)
        XCTAssertTrue(EnvelopeStore(service: service).records.isEmpty)
    }

    // MARK: - Redaction

    func testDiagnosticLogRedactsClaimLinks() {
        let line = "opened \(vectorLink) from Messages"
        let redacted = DiagnosticLog.redactingCredentials(in: EnvelopeLink.redacted(in: line))
        XCTAssertEqual(redacted, "opened https://monero.one/c#<redacted> from Messages")
        XCTAssertFalse(redacted.contains("cogs"))
        XCTAssertEqual(EnvelopeLink.redacted(in: "MONERO.ONE/c#v=1&s=a-b"), "MONERO.ONE/c#<redacted>")
        XCTAssertEqual(EnvelopeLink.redacted(in: "no link here"), "no link here")
        // A percent-encoded fragment is a link too.
        XCTAssertEqual(EnvelopeLink.redacted(in: "monero.one/c%23v=1&s=cogs-aloof"), "monero.one/c#<redacted>")
    }

    func testEnvelopeCacheIdIsOutsideTheSweep() {
        let id = EnvelopeRuntime.cacheId(for: "0123456789abcdef")
        XCTAssertEqual(id, "envelopes/0123456789abcdef")
        // The launch sweep deletes only 32-hex directory names.
        XCTAssertFalse(id.count == 32 && id.allSatisfy(\.isHexDigit))
        XCTAssertTrue(EnvelopeRuntime.directory(for: "0123456789abcdef")?.path.hasSuffix("MoneroKit/envelopes/0123456789abcdef") ?? false)
    }

    // MARK: - Sharing

    /// Messages gets the bare link with our own preview; every other app
    /// gets the usual text. The preview is built here, never fetched.
    @MainActor
    func testShareItemGivesMessagesTheLinkWithItsOwnPreview() throws {
        let record = EnvelopeRecord(id: "0123456789abcdef", role: .sent, words: vectorWords, address: vectorAddress,
                                    restoreHeight: 150, amount: 100_000_000_000, expiry: 1_791_000_000,
                                    createdAt: Date(), status: .pending)
        let item = try XCTUnwrap(PaymentLinkShareItem(record: record))
        XCTAssertEqual(item.url.absoluteString, vectorLink)
        XCTAssertEqual(PaymentLinkShareItem.title, "Claim your Monero")

        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .message) as? URL, item.url)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .mail) as? String, item.text)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? String, item.text)
        XCTAssertTrue(item.text.hasSuffix(vectorLink))

        let metadata = item.linkMetadata()
        XCTAssertEqual(metadata.title, "Claim your Monero")
        XCTAssertEqual(metadata.url, item.url)
        XCTAssertEqual(metadata.originalURL, item.url)
        // One provider: the square card feeds the bubble and the share sheet header.
        XCTAssertNotNil(metadata.imageProvider)
        XCTAssertNil(metadata.iconProvider)
        XCTAssertTrue(metadata.imageProvider?.canLoadObject(ofClass: UIImage.self) ?? false)
        // Drawn once per share.
        XCTAssertTrue(item.linkMetadata() === metadata)
    }

    /// The card is 1200 x 1200 px.
    @MainActor
    func testLinkCardImageSize() throws {
        let card = try XCTUnwrap(PaymentLinkCard.image(amount: 50_000_000_000))
        XCTAssertEqual(card.size.width * card.scale, 1200)
        XCTAssertEqual(card.size.height * card.scale, 1200)
    }

    func testLinkCardShowsTheFullAmount() {
        XCTAssertEqual(PaymentLinkCard.amountText(50_000_000_000), "0.05")
        XCTAssertEqual(PaymentLinkCard.amountText(1_000_000_000_000), "1")
        XCTAssertEqual(PaymentLinkCard.amountText(12_345_678_901_200), "12.3456789012")
        // With the real font: short and mid-length amounts show in full.
        XCTAssertEqual(PaymentLinkCard.amount(1_000_000_000_000), .init(text: "1", scale: 1))
        XCTAssertEqual(PaymentLinkCard.amount(50_000_000_000).text, "0.05")
        XCTAssertEqual(PaymentLinkCard.amount(25_404_800_000).text, "0.0254048")
        XCTAssertEqual(PaymentLinkCard.amount(12_345_678_901_200).text, "~12.35")
    }

    /// The card shrinks the amount first, then rounds it with "~", and
    /// never shows "XMR" alone.
    func testLinkCardShrinksThenRounds() {
        // 210 per character: 1008 fits 4.8 characters, 40% fits 12.
        let width: (String) -> CGFloat = { CGFloat($0.count) * 210 }
        func card(_ piconero: UInt64) -> PaymentLinkCard.Amount {
            PaymentLinkCard.amount(piconero, width: width)
        }
        XCTAssertEqual(card(50_000_000_000), .init(text: "0.05", scale: 1))
        XCTAssertEqual(card(25_404_800_000).text, "0.0254048")
        XCTAssertEqual(card(25_404_800_000).scale, 1008 / 1890, accuracy: 0.0001)
        XCTAssertEqual(card(12_345_678_901_200).text, "~12.35")
        XCTAssertEqual(card(123_456_789).text, "~0.00012")
        XCTAssertEqual(card(1_234_567_891_234_000_000).text, "~1,234,568")
        let tiny = card(1)
        XCTAssertEqual(tiny.text, "0.000000000001")
        XCTAssertLessThan(tiny.scale, PaymentLinkCard.minimumScale)
        XCTAssertGreaterThan(tiny.scale, 0)
    }
}
