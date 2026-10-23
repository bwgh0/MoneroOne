import XCTest
import UIKit
import Security
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
        // The sentence's punctuation after a v1 link is not part of it.
        XCTAssertEqual(try EnvelopeLink.parse(vectorLink + "."), vector)
        XCTAssertEqual(try EnvelopeLink.parse(vectorLink + ")"), vector)
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

    private func obs(seen: Bool = true, conf: Int = 0, balance: UInt64 = 0, unlocked: UInt64 = 0, spends: [String] = [], mined: [String] = []) -> EnvelopeObservation {
        EnvelopeObservation(fundingSeen: seen, fundingConfirmations: conf, balance: balance, unlockedBalance: unlocked,
                            spendTxids: spends, minedSpendTxids: mined)
    }

    func testStatusTable() {
        let rules = EnvelopeStatusRules.self
        XCTAssertEqual(rules.status(for: .empty), .notFunded)
        // In the pool: seen, no balance yet.
        XCTAssertEqual(rules.status(for: obs(conf: 0)), .pending)
        XCTAssertEqual(rules.status(for: obs(conf: 3, balance: 5)), .pending)
        XCTAssertEqual(rules.status(for: obs(conf: 10, balance: 5, unlocked: 5)), .ready)
        // Balance gone with a spend on chain: claimed.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"], mined: ["claim"])), .claimed)
        // Balance zero, no spend seen: not claimed yet (pool or stale read).
        XCTAssertEqual(rules.status(for: obs(conf: 12)), .pending)
    }

    /// Our reclaim went out. The link stays Reclaimed until the scan sees
    /// it in a block with spendable money left behind; a claim that beat it
    /// reads Claimed.
    func testAReclaimedLinkReopensOnlyAfterItsReclaimIsMined() {
        func status(_ observation: EnvelopeObservation, _ current: EnvelopeStatus = .reclaimed) -> EnvelopeStatus {
            EnvelopeStatusRules.status(for: observation, current: current, role: .sent, settleTxid: "ours", fundingKnown: true)
        }
        XCTAssertEqual(status(obs(conf: 12, spends: ["ours"], mined: ["ours"])), .reclaimed)
        // Still in the pool: a fresh envelope may not see it, and sees the
        // money. However long it waits, it does not reopen.
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5)), .reclaimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5, spends: ["ours"])), .reclaimed)
        // Mined, and a newer funding is still locked: settled for now.
        XCTAssertEqual(status(obs(conf: 12, balance: 7, spends: ["ours"], mined: ["ours"])), .reclaimed)
        // Mined, and spendable money is left: open again.
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["ours"], mined: ["ours"])), .ready)
        // A claim won the race against our reclaim: Claimed, and final.
        XCTAssertEqual(status(obs(conf: 12, spends: ["claim"], mined: ["claim"])), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5, spends: ["claim"], mined: ["claim"])), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5, spends: ["claim", "ours"], mined: ["claim", "ours"]), .claimed), .claimed)
        // Open links follow the base rules, whatever an old reclaim says.
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5, spends: ["ours"], mined: ["ours"]), .ready), .ready)
    }

    /// Our claim, and links settled elsewhere: the same rule.
    func testAClaimedLinkReopensOnlyAfterItsClaimIsMined() {
        func status(_ observation: EnvelopeObservation, _ current: EnvelopeStatus, _ role: EnvelopeRecord.Role, _ settle: String?) -> EnvelopeStatus {
            EnvelopeStatusRules.status(for: observation, current: current, role: role, settleTxid: settle)
        }
        // Our claim waits in the pool: the scan sees the money. Still Claimed.
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5), .claimed, .received, "mine"), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 5, unlocked: 5, spends: ["mine"]), .claimed, .received, "mine"), .claimed)
        XCTAssertEqual(status(obs(conf: 12, spends: ["mine"], mined: ["mine"]), .claimed, .received, "mine"), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, spends: ["mine"], mined: ["mine"]), .claimed, .received, "mine"), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["mine"], mined: ["mine"]), .claimed, .received, "mine"), .ready)
        // Claimed by the recipient (sent), or reclaimed by the sender (received).
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["claim"]), .claimed, .sent, nil), .claimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["claim"], mined: ["claim"]), .claimed, .sent, nil), .ready)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["back"], mined: ["back"]), .reclaimed, .received, nil), .ready)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7), .reclaimed, .received, nil), .reclaimed)
    }

    func testTheLeftoverCheckOfASettledLink() {
        let rules = EnvelopeStatusRules.self
        // Conclusive: the settle is in a block and nothing is left locked.
        XCTAssertTrue(rules.leftoverCheckIsConclusive(role: .received, settleTxid: "mine", observation: obs(conf: 12, spends: ["mine"], mined: ["mine"])))
        XCTAssertTrue(rules.leftoverCheckIsConclusive(role: .received, settleTxid: "mine", observation: obs(conf: 12, balance: 7, unlocked: 7, spends: ["mine"], mined: ["mine"])))
        XCTAssertFalse(rules.leftoverCheckIsConclusive(role: .received, settleTxid: "mine", observation: obs(conf: 12, spends: ["mine"])))
        XCTAssertFalse(rules.leftoverCheckIsConclusive(role: .received, settleTxid: "mine", observation: obs(conf: 12, balance: 7, spends: ["mine"], mined: ["mine"])))
        XCTAssertFalse(rules.leftoverCheckIsConclusive(role: .sent, settleTxid: nil, observation: obs(conf: 12)))
        XCTAssertTrue(rules.leftoverCheckIsConclusive(role: .sent, settleTxid: nil, observation: obs(conf: 12, spends: ["claim"], mined: ["claim"])))

        let now = Date()
        func due(_ role: EnvelopeRecord.Role, _ status: EnvelopeStatus, settle: String? = "mine", checked: TimeInterval? = nil,
                 history: [MoneroTransaction] = []) -> Bool {
            var record = storeRecord(UUID().uuidString, role)
            record.status = status
            record.settleTxid = settle
            record.lastCheckedAt = checked.map { now.addingTimeInterval(-$0) }
            return rules.isLeftoverCheckDue(record, transactions: history, now: now, interval: 120)
        }
        XCTAssertTrue(due(.received, .claimed))
        XCTAssertTrue(due(.sent, .reclaimed))
        XCTAssertTrue(due(.sent, .claimed, settle: nil))
        XCTAssertFalse(due(.received, .ready))
        // A claim beat our reclaim: final.
        XCTAssertFalse(due(.sent, .claimed))
        // At most one look every 2 minutes.
        XCTAssertFalse(due(.received, .claimed, checked: 60))
        XCTAssertTrue(due(.received, .claimed, checked: 600))
        // Our claim still waits in this wallet's pool: a look cannot reopen it.
        func claim(_ status: MoneroTransaction.TransactionStatus) -> MoneroTransaction {
            MoneroTransaction(id: "mine", type: .incoming, amount: 1, fee: 0, address: "", timestamp: now, confirmations: nil,
                              status: status, memo: nil, blockHeight: status == .confirmed ? 100 : nil)
        }
        XCTAssertFalse(due(.received, .claimed, history: [claim(.pending)]))
        XCTAssertTrue(due(.received, .claimed, history: [claim(.confirmed)]))
        XCTAssertTrue(due(.received, .claimed, history: [claim(.failed)]))
    }

    // MARK: - Dropped settles and hidden attempts

    private func history(_ id: String, _ status: MoneroTransaction.TransactionStatus) -> MoneroTransaction {
        MoneroTransaction(id: id, type: .incoming, amount: 1, fee: 0, address: "", timestamp: Date(), confirmations: nil,
                          status: status, memo: nil, blockHeight: status == .confirmed ? 100 : nil)
    }

    func testASettleCountsAsDroppedOnlyOutOfThePoolPastItsGrace() {
        let rules = EnvelopeStatusRules.self
        let now = Date()
        let sentAt = now.addingTimeInterval(-(rules.settleGrace + 60))
        let money = obs(conf: 12, balance: 7, unlocked: 7)
        func failed(_ observation: EnvelopeObservation, at settledAt: Date? = sentAt, _ transactions: [MoneroTransaction] = []) -> Bool {
            rules.settleHasFailed(settleTxid: "mine", settledAt: settledAt, observation: observation, transactions: transactions, now: now)
        }
        XCTAssertEqual(rules.settleGrace, 60 * 60)
        // Past the grace, in no block, not in this wallet's pool: dropped.
        XCTAssertTrue(failed(money))
        // Inside its grace: waits.
        XCTAssertFalse(failed(money, at: now.addingTimeInterval(-(rules.settleGrace - 60))))
        // In this wallet's pool, or mined in it: waits, however long.
        XCTAssertFalse(failed(money, [history("mine", .pending)]))
        XCTAssertFalse(failed(money, [history("mine", .confirmed)]))
        // wallet2 marks it failed: dropped at once.
        XCTAssertTrue(failed(money, at: now, [history("mine", .failed)]))
        // The envelope sees it, in the pool or in a block.
        XCTAssertFalse(failed(obs(conf: 12, spends: ["mine"])))
        XCTAssertFalse(failed(obs(conf: 12, spends: ["mine"], mined: ["mine"])))
        // No send time: only wallet2's mark counts.
        XCTAssertFalse(failed(money, at: nil))
        XCTAssertFalse(rules.settleHasFailed(settleTxid: nil, settledAt: sentAt, observation: money, transactions: [], now: now))
    }

    func testADroppedSettleReopensWhenTheMoneyIsSpendable() {
        func status(_ observation: EnvelopeObservation, _ current: EnvelopeStatus, _ role: EnvelopeRecord.Role, failed: Bool) -> EnvelopeStatus {
            EnvelopeStatusRules.status(for: observation, current: current, role: role, settleTxid: "mine", settleFailed: failed)
        }
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7), .reclaimed, .sent, failed: true), .ready)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7), .claimed, .received, failed: true), .ready)
        // Not dropped (pool or grace): settled.
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7), .reclaimed, .sent, failed: false), .reclaimed)
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7), .claimed, .received, failed: false), .claimed)
        // Dropped, but nothing spendable: settled.
        XCTAssertEqual(status(obs(conf: 12, balance: 7), .claimed, .received, failed: true), .claimed)
        XCTAssertEqual(status(obs(conf: 12), .reclaimed, .sent, failed: true), .reclaimed)
        // A claim took it: Claimed, dropped reclaim or not.
        XCTAssertEqual(status(obs(conf: 12, balance: 7, unlocked: 7, spends: ["claim"], mined: ["claim"]), .reclaimed, .sent, failed: true), .claimed)
    }

    /// A sweep the node accepted, then evicted with no replacement, across
    /// an app restart: the money is claimable (or reclaimable) again.
    @MainActor
    func testAnEvictedSweepReopensTheLinkAfterARestart() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        let now = Date()
        let sentAt = now.addingTimeInterval(-2 * EnvelopeStatusRules.settleGrace)
        var claimed = storeRecord(vector.id, .received)
        claimed.status = .claimed
        claimed.settleTxid = "evicted-claim"
        claimed.settledAmount = 7
        claimed.settledAt = sentAt
        claimed.walletName = "Main"
        try store.save(claimed)
        var reclaimed = storeRecord("0123456789abcdef", .sent)
        reclaimed.walletId = "w1"
        reclaimed.expiry = Int64(now.timeIntervalSince1970) + 86_400
        reclaimed.fundingTxid = "funding"
        reclaimed.status = .reclaimed
        reclaimed.settleTxid = "evicted-reclaim"
        reclaimed.settledAt = sentAt
        try store.save(reclaimed)

        // Relaunch: the records come back from the Keychain.
        let relaunched = EnvelopeStore(service: service)
        let received = try XCTUnwrap(relaunched.record(id: vector.id, role: .received))
        let sent = try XCTUnwrap(relaunched.record(id: "0123456789abcdef", role: .sent))
        // Not seen mined, not in this wallet: the dashboard looks at both.
        XCTAssertTrue(OpenPaymentLinks.needsLook(received, activeWalletId: "w1", transactions: [], now: now))
        XCTAssertTrue(OpenPaymentLinks.needsLook(sent, activeWalletId: "w1", transactions: [], now: now))

        // A fresh envelope scan: the money is still there, no spend.
        let money = obs(conf: 30, balance: 7, unlocked: 7)
        let claim = PaymentLinksStatusChecker.applying(money, to: received, transactions: [], now: now).record
        XCTAssertEqual(claim.status, .ready)
        XCTAssertNil(claim.settleTxid)
        XCTAssertNil(claim.settledAmount)
        XCTAssertNil(claim.walletName)
        XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(claim, now: now))
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: claim, display: PaymentLinkDisplay(record: claim, fundingConfirmations: nil, daemonHeight: nil)), [.claim])

        let reclaim = PaymentLinksStatusChecker.applying(money, to: sent, transactions: [], now: now).record
        XCTAssertEqual(reclaim.status, .ready)
        XCTAssertNil(reclaim.settleTxid)
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(reclaim, activeWalletId: "w1"))
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: reclaim, display: PaymentLinkDisplay(record: reclaim, fundingConfirmations: nil, daemonHeight: nil)),
                       [.share, .reclaim])

        // The same scan while the claim waits in this wallet's pool: no change.
        let waiting = PaymentLinksStatusChecker.applying(money, to: received, transactions: [history("evicted-claim", .pending)], now: now).record
        XCTAssertEqual(waiting.status, .claimed)
        XCTAssertEqual(waiting.settledAmount, 7)
        XCTAssertFalse(OpenPaymentLinks.needsLook(received, activeWalletId: "w1", transactions: [history("evicted-claim", .pending)], now: now))
        // Seen mined once: no more background looks.
        let mined = PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["evicted-claim"], mined: ["evicted-claim"]), to: received, transactions: [], now: now)
        XCTAssertEqual(mined.record.status, .claimed)
        XCTAssertTrue(mined.conclusive)
        XCTAssertEqual(mined.record.settleSeenMined, true)
        XCTAssertFalse(EnvelopeStatusRules.needsSettleLook(mined.record, transactions: []))
    }

    /// Reclaimed, opened again by more money, reclaimed again: a scan that
    /// shows the first reclaim (and not yet the second) never reads it as a
    /// claim that beat ours. The earlier spends survive a restart.
    @MainActor
    func testASecondReclaimNeverReadsTheFirstAsAClaim() throws {
        let now = Date()
        var sent = storeRecord("0123456789abcdef", .sent)
        sent.walletId = "w1"
        sent.expiry = Int64(now.timeIntervalSince1970) + 86_400
        sent.fundingTxid = "funding"
        sent.status = .reclaimed
        sent.settleTxid = "first"
        sent.settledAt = now.addingTimeInterval(-3_600)
        XCTAssertNil(sent.spendsBeforeSettle)

        // More money came after the first reclaim was mined: open again.
        let topUp = obs(conf: 30, balance: 5, unlocked: 5, spends: ["first"], mined: ["first"])
        let reopened = PaymentLinksStatusChecker.applying(topUp, to: sent, transactions: [], now: now).record
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertNil(reopened.settleTxid)
        XCTAssertEqual(reopened.spendsBeforeSettle, ["first"])

        // Saved and read back after a relaunch.
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        try store.save(reopened)
        var again = try XCTUnwrap(EnvelopeStore(service: service).record(id: "0123456789abcdef", role: .sent))
        XCTAssertEqual(again.spendsBeforeSettle, ["first"])

        // The second reclaim goes out (as EnvelopeSession.sweep records it).
        again.settleTxid = "second"
        again.settledAt = now
        again.status = .reclaimed
        func scan(_ observation: EnvelopeObservation) -> EnvelopeRecord {
            PaymentLinksStatusChecker.applying(observation, to: again, transactions: [], now: now).record
        }
        // The second still waits in the pool: the scan shows only the first.
        XCTAssertEqual(scan(obs(conf: 30, balance: 5, unlocked: 5, spends: ["first"], mined: ["first"])).status, .reclaimed)
        XCTAssertEqual(scan(obs(conf: 30, spends: ["first"], mined: ["first"])).status, .reclaimed)
        // Both mined, the envelope empty: Reclaimed, and the check is done.
        let both = obs(conf: 30, spends: ["first", "second"], mined: ["first", "second"])
        XCTAssertEqual(scan(both).status, .reclaimed)
        XCTAssertTrue(PaymentLinksStatusChecker.applying(both, to: again, transactions: [], now: now).conclusive)
        // A new spend that is not ours, and ours not seen: a claim beat it.
        XCTAssertEqual(scan(obs(conf: 30, spends: ["first", "claim"], mined: ["first", "claim"])).status, .claimed)

        // A claim made elsewhere settled the link first, then more money
        // came: the claim stays older than our reclaim.
        var claimedFirst = sent
        claimedFirst.status = .claimed
        claimedFirst.settleTxid = nil
        claimedFirst.settledAt = nil
        let open = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 5, unlocked: 5, spends: ["their-claim"], mined: ["their-claim"]),
                                                      to: claimedFirst, transactions: [], now: now).record
        XCTAssertEqual(open.status, .ready)
        XCTAssertEqual(open.spendsBeforeSettle, ["their-claim"])
        var ours = open
        ours.settleTxid = "ours"
        ours.settledAt = now
        ours.status = .reclaimed
        XCTAssertEqual(PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 5, unlocked: 5, spends: ["their-claim"], mined: ["their-claim"]),
                                                          to: ours, transactions: [], now: now).record.status, .reclaimed)
    }

    /// Our reclaim read as dropped and the link opened again, then the
    /// reclaim was mined after all: Reclaimed, not Claimed.
    func testALateMinedOldReclaimReadsReclaimed() {
        let now = Date()
        var sent = storeRecord("0123456789abcdef", .sent)
        sent.walletId = "w1"
        sent.expiry = Int64(now.timeIntervalSince1970) + 86_400
        sent.fundingTxid = "funding"
        sent.status = .reclaimed
        sent.settleTxid = "slow"
        sent.settledAt = now.addingTimeInterval(-2 * EnvelopeStatusRules.settleGrace)
        // Past its grace, seen nowhere: dropped, the link opens again.
        let reopened = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 7, unlocked: 7), to: sent, transactions: [], now: now).record
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertNil(reopened.settleTxid)
        XCTAssertEqual(reopened.spendsBeforeSettle, ["slow"])

        func scan(_ observation: EnvelopeObservation) -> EnvelopeStatus {
            PaymentLinksStatusChecker.applying(observation, to: reopened, transactions: [], now: now).record.status
        }
        XCTAssertEqual(scan(obs(conf: 30, spends: ["slow"], mined: ["slow"])), .reclaimed)
        // Another spend took the money: Claimed.
        XCTAssertEqual(scan(obs(conf: 30, spends: ["claim"], mined: ["claim"])), .claimed)
        XCTAssertEqual(scan(obs(conf: 30, spends: ["slow", "claim"], mined: ["slow", "claim"])), .claimed)
        // A received link: our old claim, mined late, is still a claim.
        var received = storeRecord("0123456789abcdef", .received)
        received.status = .claimed
        received.settleTxid = "slow"
        received.settledAt = sent.settledAt
        let claimable = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 7, unlocked: 7), to: received, transactions: [], now: now).record
        XCTAssertEqual(claimable.status, .ready)
        XCTAssertEqual(claimable.spendsBeforeSettle, ["slow"])
        XCTAssertEqual(PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["slow"], mined: ["slow"]), to: claimable, transactions: [], now: now).record.status,
                       .claimed)
    }

    /// Records saved before `spendsBeforeSettle` existed decode with none.
    func testOldRecordsDecodeWithNoEarlierSpends() throws {
        var record = storeRecord("0123456789abcdef", .sent)
        record.spendsBeforeSettle = nil
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("spendsBeforeSettle"))
        let decoded = try JSONDecoder().decode(EnvelopeRecord.self, from: data)
        XCTAssertNil(decoded.spendsBeforeSettle)
        XCTAssertEqual(decoded, record)
    }

    func testOnlyErrorsBeforeTheBroadcastSkipTheHiddenScan() {
        XCTAssertTrue(WalletManager.sendLeftNothingOnNetwork(MoneroCoreError.transactionSendFailed("not enough unlocked money")))
        XCTAssertTrue(WalletManager.sendLeftNothingOnNetwork(MoneroCoreError.insufficientFunds("1.0")))
        XCTAssertTrue(WalletManager.sendLeftNothingOnNetwork(MoneroCoreError.walletNotInitialized))
        XCTAssertTrue(WalletManager.sendLeftNothingOnNetwork(WalletError.viewOnlyCannotSend))
        XCTAssertTrue(WalletManager.sendLeftNothingOnNetwork(WalletError.notUnlocked))
        XCTAssertFalse(WalletManager.sendLeftNothingOnNetwork(MoneroCoreError.transactionCommitFailed("relay")))
        XCTAssertFalse(WalletManager.sendLeftNothingOnNetwork(MoneroCoreError.walletStatusError("?")))
        XCTAssertFalse(WalletManager.sendLeftNothingOnNetwork(URLError(.timedOut)))
    }

    func testAHiddenAttemptIsScannedForADayOfBlocks() {
        let now = Date()
        var attempt = storeRecord("0123456789abcdef", .sent)
        attempt.status = .notFunded
        attempt.fundingStartedAt = now.addingTimeInterval(-60)
        let rules = EnvelopeStatusRules.self
        XCTAssertTrue(rules.needsFundingScan(attempt, now: now))
        // Until the scan reaches the attempt (restore height + 10) + 720 blocks.
        let end = attempt.restoreHeight + EnvelopeLink.restoreHeightMargin + rules.fundingScanBlocks
        var scanned = attempt
        scanned.lastScannedHeight = end - 1
        XCTAssertTrue(rules.needsFundingScan(scanned, now: now))
        scanned.lastScannedHeight = end
        XCTAssertFalse(rules.needsFundingScan(scanned, now: now))
        XCTAssertNotNil(scanned.link)
        // Failed before anything was sent: no scan.
        var notSent = attempt
        notSent.fundingNotSent = true
        XCTAssertFalse(rules.needsFundingScan(notSent, now: now))
        // Never attempted, or funded: no scan.
        var draft = attempt
        draft.fundingStartedAt = nil
        XCTAssertFalse(rules.needsFundingScan(draft, now: now))
        var funded = attempt
        funded.fundingTxid = "f"
        XCTAssertFalse(rules.needsFundingScan(funded, now: now))
        // The app closed during the attempt: a send still running gets time.
        var interrupted = attempt
        interrupted.status = .created
        XCTAssertFalse(rules.needsFundingScan(interrupted, now: now))
        interrupted.fundingStartedAt = now.addingTimeInterval(-11 * 60)
        XCTAssertTrue(rules.needsFundingScan(interrupted, now: now))
        // The dashboard looks at it in the wallet that made the attempt only.
        attempt.walletId = "w1"
        XCTAssertTrue(OpenPaymentLinks.needsLook(attempt, activeWalletId: "w1", transactions: [], now: now))
        XCTAssertFalse(OpenPaymentLinks.needsLook(attempt, activeWalletId: "w2", transactions: [], now: now))
    }

    /// The node took the funding, its answer was lost, and no funding hash
    /// is known. Mined later, the scan finds it: the link shows as Waiting.
    @MainActor
    func testAHiddenAttemptReappearsWhenTheScanFindsItsFunding() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .sent)
        record.walletId = "w1"
        record.expiry = Int64(Date().timeIntervalSince1970) + 86_400
        try PaymentLinkFunder.save(record, store: store, networkType: .mainnet)
        try PaymentLinkFunder.beginFunding(record, walletId: "w1", store: store, networkType: .mainnet)
        PaymentLinkFunder.markNotFunded(id: record.id, store: store)
        let hidden = try XCTUnwrap(EnvelopeStore(service: service).record(id: record.id, role: .sent))
        XCTAssertNil(hidden.fundingNotSent)
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(hidden, activeWalletId: "w1"))
        XCTAssertTrue(OpenPaymentLinks.needsLook(hidden, activeWalletId: "w1", transactions: [], now: Date()))

        // A scan before the funding is mined, and one that sees nothing.
        var nothing = EnvelopeObservation.empty
        nothing.height = 200
        let early = PaymentLinksStatusChecker.applying(nothing, to: hidden, transactions: [], now: Date()).record
        XCTAssertEqual(early.status, .notFunded)
        XCTAssertEqual(early.lastScannedHeight, 200)
        XCTAssertTrue(EnvelopeStatusRules.needsFundingScan(early, now: Date()))

        var funded = obs(conf: 2, balance: 5)
        funded.fundingTxids = ["lost-answer"]
        funded.fundingHeight = 205
        funded.height = 207
        let found = PaymentLinksStatusChecker.applying(funded, to: early, transactions: [], now: Date()).record
        XCTAssertEqual(found.fundingTxid, "lost-answer")
        XCTAssertEqual(found.status, .pending)
        XCTAssertEqual(found.lastScannedHeight, 207)
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(found, activeWalletId: "w1"))
        XCTAssertFalse(EnvelopeStatusRules.needsFundingScan(found, now: Date()))
        let display = PaymentLinkDisplay(record: found, fundingConfirmations: 2, daemonHeight: nil)
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: found, display: display), [.share, .reclaim])

        // A failure known to come before the broadcast is never scanned.
        let otherStore = EnvelopeStore(service: service + ".other")
        defer { otherStore.removeAll() }
        try PaymentLinkFunder.save(record, store: otherStore, networkType: .mainnet)
        try PaymentLinkFunder.beginFunding(record, walletId: "w1", store: otherStore, networkType: .mainnet)
        PaymentLinkFunder.markNotFunded(id: record.id, nothingSent: true, store: otherStore)
        let notSent = try XCTUnwrap(otherStore.record(id: record.id, role: .sent))
        XCTAssertEqual(notSent.fundingNotSent, true)
        XCTAssertFalse(OpenPaymentLinks.needsLook(notSent, activeWalletId: "w1", transactions: [], now: Date()))
    }

    /// Link 10: the wallet's history has the funding, the envelope's scan
    /// did not see it. The link waits; it is never Not funded.
    func testAKnownFundingIsNeverNotFunded() {
        let rules = EnvelopeStatusRules.self
        XCTAssertEqual(rules.status(for: .empty, fundingKnown: true), .pending)
        XCTAssertEqual(rules.status(for: .empty, fundingKnown: false), .notFunded)
        // What the scan sees still wins once it sees the funding.
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 5, unlocked: 5), fundingKnown: true), .ready)
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"]), fundingKnown: true), .claimed)

        XCTAssertEqual(rules.reconciled(.notFunded, role: .sent, fundingTxid: "f"), .pending)
        XCTAssertEqual(rules.reconciled(.created, role: .sent, fundingTxid: "f"), .pending)
        XCTAssertEqual(rules.reconciled(.notFunded, role: .sent, fundingTxid: nil), .notFunded)
        XCTAssertEqual(rules.reconciled(.created, role: .sent, fundingTxid: nil), .created)
        XCTAssertEqual(rules.reconciled(.ready, role: .sent, fundingTxid: "f"), .ready)
        XCTAssertEqual(rules.reconciled(.claimed, role: .sent, fundingTxid: "f"), .claimed)
        XCTAssertEqual(rules.reconciled(.reclaimed, role: .sent, fundingTxid: "f"), .reclaimed)
        XCTAssertEqual(rules.reconciled(.notFunded, role: .received, fundingTxid: "f"), .notFunded)
    }

    func testTheEnvelopeScanStartsNoLaterThanTheFundingBlock() {
        let rules = EnvelopeStatusRules.self
        XCTAssertEqual(rules.scanFloor(restoreHeight: 100, fundingHeight: 90), 90)
        XCTAssertEqual(rules.scanFloor(restoreHeight: 100, fundingHeight: 150), 100)
        XCTAssertEqual(rules.scanFloor(restoreHeight: 100, fundingHeight: nil), 100)
        XCTAssertEqual(rules.scanFloor(restoreHeight: 100, fundingHeight: 0), 100)
    }

    /// The repro: an envelope saved before its first scan reopened with its
    /// scan start moved to the tip (1947), above its funding block (1934).
    func testAnEnvelopeThatMissedItsFundingIsScannedAgain() {
        func rescan(start: UInt64, floor: UInt64 = 1934, seen: Bool = false, funding: UInt64? = 1934,
                    height: UInt64 = 1947, done: Bool = false) -> Bool {
            EnvelopeStatusRules.needsRescan(scanStart: start, floor: floor, fundingSeen: seen, fundingHeight: funding,
                                            walletHeight: height, alreadyRescanned: done)
        }
        // The scan started above the floor: always scan again.
        XCTAssertTrue(rescan(start: 1947))
        XCTAssertTrue(rescan(start: 1947, seen: true))
        XCTAssertTrue(rescan(start: 1947, funding: nil))
        // It started low enough and saw the funding.
        XCTAssertFalse(rescan(start: 1934, seen: true))
        XCTAssertFalse(rescan(start: 1900, seen: true))
        // It started low enough but missed a mined funding: once per run.
        XCTAssertTrue(rescan(start: 1934))
        XCTAssertFalse(rescan(start: 1934, done: true))
        // A funding in the pool, or one above the wallet's height: wait.
        XCTAssertFalse(rescan(start: 1934, funding: nil))
        XCTAssertFalse(rescan(start: 1934, height: 1934))
    }

    /// Saved envelope files are reused only with a recorded scan start at
    /// or below the floor. Files with none (the app was killed before the
    /// first save, files from before the record) are rebuilt (Link 18:
    /// a kill during a received link's first scan).
    func testSavedEnvelopeFilesNeedARecordedScanStart() {
        let rules = EnvelopeStatusRules.self
        XCTAssertFalse(rules.canReuseScan(savedStart: nil, floor: 1608))
        XCTAssertTrue(rules.canReuseScan(savedStart: 1608, floor: 1608))
        XCTAssertTrue(rules.canReuseScan(savedStart: 1500, floor: 1608))
        // A scan from higher up missed blocks the floor needs.
        XCTAssertFalse(rules.canReuseScan(savedStart: 1964, floor: 1608))
    }

    /// The scan start is recorded once the first refresh pulled the hashes
    /// to it: before that the wallet holds one block, and its save would
    /// make the next open skip to the tip.
    func testTheScanStartIsRecordedAfterTheFirstRefresh() {
        let rules = EnvelopeStatusRules.self
        XCTAssertFalse(rules.hasRefreshed(walletHeight: 0, scanFrom: 1608))
        XCTAssertFalse(rules.hasRefreshed(walletHeight: 1, scanFrom: 1608))
        XCTAssertFalse(rules.hasRefreshed(walletHeight: 1607, scanFrom: 1608))
        XCTAssertTrue(rules.hasRefreshed(walletHeight: 1608, scanFrom: 1608))
        XCTAssertTrue(rules.hasRefreshed(walletHeight: 1964, scanFrom: 1608))
        // A start of 0 or 1 still needs a refresh past the first block.
        XCTAssertFalse(rules.hasRefreshed(walletHeight: 1, scanFrom: 0))
        XCTAssertTrue(rules.hasRefreshed(walletHeight: 2, scanFrom: 0))
    }

    func testTheScanStartRecordRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // No folder: nothing written, nothing read.
        EnvelopeRuntime.markScanStart(in: dir, from: 1608)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(EnvelopeRuntime.savedScanStart(in: dir))
        XCTAssertNil(EnvelopeRuntime.walletSavedAt(in: dir))

        let core = dir.appendingPathComponent("network_0/monero_core")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        XCTAssertNil(EnvelopeRuntime.savedScanStart(in: dir))
        EnvelopeRuntime.markScanStart(in: dir, from: 1608)
        XCTAssertEqual(EnvelopeRuntime.savedScanStart(in: dir), 1608)
        EnvelopeRuntime.markScanStart(in: dir, from: 1500)
        XCTAssertEqual(EnvelopeRuntime.savedScanStart(in: dir), 1500)

        // The save time is the wallet cache's, not the keys file's.
        let saved = Date(timeIntervalSince1970: 1_792_000_000)
        let keys = core.appendingPathComponent("wallet.keys")
        let cache = core.appendingPathComponent("wallet")
        try Data([1]).write(to: keys)
        XCTAssertNil(EnvelopeRuntime.walletSavedAt(in: dir))
        try Data([1]).write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: saved], ofItemAtPath: cache.path)
        try FileManager.default.setAttributes([.modificationDate: saved.addingTimeInterval(60)], ofItemAtPath: keys.path)
        XCTAssertEqual(EnvelopeRuntime.walletSavedAt(in: dir), saved)
    }

    func testTheLogNamesTheLinkByItsNumberOnly() {
        XCTAssertEqual(EnvelopeRuntime.logName(7), "Link 7")
        XCTAssertEqual(EnvelopeRuntime.logName(nil), "Link ?")
        let line = "Envelope check: \(EnvelopeRuntime.logName(7)), height 1947/1947, scan from 1934, funded true"
        XCTAssertEqual(DiagnosticLog.redactingCredentials(in: EnvelopeLink.redacted(in: line)), line)
        let failed = "Payment link check failed: \(EnvelopeRuntime.logName(10)): opened \(vectorLink)"
        XCTAssertEqual(EnvelopeLink.redacted(in: failed), "Payment link check failed: Link 10: opened https://monero.one/c#<redacted>")
    }

    /// No state of any link offers Retry or Remove; a sent link with a
    /// funding transaction offers Share whatever the last scan said.
    @MainActor
    func testLinkActions() {
        func actions(_ role: EnvelopeRecord.Role, _ status: EnvelopeStatus, fundingTxid: String? = "f",
                     funding: Int? = nil, expired: Bool = false, secret: Bool = true) -> [PaymentLinkDetailAction] {
            var record = storeRecord(UUID().uuidString, role)
            record.status = status
            record.fundingTxid = role == .sent ? fundingTxid : nil
            record.expiry = expired ? Int64(Date().timeIntervalSince1970) - 60 : 0
            if !secret { record.words = nil }
            let display = PaymentLinkDisplay(record: record, fundingConfirmations: funding, daemonHeight: nil)
            return PaymentLinkDetailAction.actions(for: record, display: display)
        }
        // Link 10: funded, the scan said Not funded.
        XCTAssertEqual(actions(.sent, .notFunded), [.share, .reclaim])
        XCTAssertEqual(actions(.sent, .notFunded, funding: 12), [.share, .reclaim])
        XCTAssertEqual(actions(.sent, .created), [.share, .reclaim])
        XCTAssertEqual(actions(.sent, .pending), [.share, .reclaim])
        XCTAssertEqual(actions(.sent, .ready), [.share, .reclaim])
        XCTAssertEqual(actions(.sent, .ready, expired: true), [.reclaim, .share])
        XCTAssertEqual(actions(.sent, .ready, secret: false), [.reclaim])
        // Never funded, or settled: nothing to do.
        XCTAssertEqual(actions(.sent, .notFunded, fundingTxid: nil), [])
        XCTAssertEqual(actions(.sent, .created, fundingTxid: nil), [])
        XCTAssertEqual(actions(.sent, .pending, fundingTxid: nil), [])
        XCTAssertEqual(actions(.sent, .ready, fundingTxid: nil), [])
        XCTAssertEqual(actions(.sent, .claimed), [])
        XCTAssertEqual(actions(.sent, .reclaimed), [])
        // A received link: Claim until it is settled.
        XCTAssertEqual(actions(.received, .pending), [.claim])
        XCTAssertEqual(actions(.received, .ready), [.claim])
        XCTAssertEqual(actions(.received, .claimed), [])
        XCTAssertEqual(actions(.received, .reclaimed), [])
        XCTAssertEqual(actions(.received, .notFunded, secret: false), [])
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
        var poolExpected = obs(conf: 0)
        poolExpected.fundingTxids = ["f"]
        poolExpected.height = 200
        XCTAssertEqual(pool, poolExpected)

        let mined = EnvelopeRuntime.observation(
            transactions: [tx("f", .incoming, height: 190), tx("c", .outgoing, height: 199, amount: "0.4", fee: "0.1"), tx("x", .outgoing, height: nil, status: .failed),
                           tx("p", .outgoing, height: nil, status: .pending, amount: "0")],
            balance: Decimal(string: "0.5")!, unlocked: Decimal(string: "0.5")!, daemonHeight: 200
        )
        // A spend in the pool is seen, not mined.
        var expected = obs(conf: 10, balance: 500_000_000_000, unlocked: 500_000_000_000, spends: ["c", "p"], mined: ["c"])
        expected.fundingHeight = 190
        expected.fundingTxids = ["f"]
        expected.height = 200
        XCTAssertEqual(mined, expected)

        // Fundings oldest first; one still in the pool last.
        let two = EnvelopeRuntime.observation(
            transactions: [tx("new", .incoming, height: nil, status: .pending), tx("old", .incoming, height: 150), tx("mid", .incoming, height: 0, status: .pending)],
            balance: 0, unlocked: 0, daemonHeight: 200
        )
        XCTAssertEqual(two.fundingTxids.first, "old")

        // Reopened from its cache, the kit still stores the balance from
        // before the claim: the history caps it at zero.
        let stale = EnvelopeRuntime.observation(
            transactions: [tx("f", .incoming, height: 280, amount: "0.5018432", fee: "0.0018084"),
                           tx("c", .outgoing, height: 291, amount: "0.5000348", fee: "0.0018084")],
            balance: Decimal(string: "0.5018432")!, unlocked: Decimal(string: "0.5018432")!, daemonHeight: 301
        )
        XCTAssertEqual(stale.balance, 0)
        XCTAssertEqual(stale.unlockedBalance, 0)
        XCTAssertEqual(EnvelopeStatusRules.status(for: stale), .claimed)
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
    func testFundingAttemptSurvivesRestartAndRejectsASecondBroadcast() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .sent)
        record.walletId = "funding-wallet"
        try PaymentLinkFunder.save(record, store: store, networkType: .mainnet)
        XCTAssertThrowsError(try PaymentLinkFunder.beginFunding(record, walletId: "another-wallet", store: store, networkType: .mainnet))
        XCTAssertNil(store.record(id: record.id, role: .sent)?.fundingStartedAt)
        try PaymentLinkFunder.beginFunding(record, walletId: record.walletId, store: store, networkType: .mainnet)
        XCTAssertNotNil(store.record(id: record.id, role: .sent)?.fundingStartedAt)
        // The lock alone does not make the link visible.
        XCTAssertEqual(store.record(id: record.id, role: .sent)?.status, .created)
        // A failed send stays hidden; history or a scan adopts it if the node took it.
        PaymentLinkFunder.markNotFunded(id: record.id, store: store)
        XCTAssertEqual(store.record(id: record.id, role: .sent)?.status, .notFunded)
        XCTAssertNotNil(store.record(id: record.id, role: .sent)?.fundingStartedAt)
        // A stale review-screen copy cannot reset the durable attempt.
        try PaymentLinkFunder.save(record, store: store, networkType: .mainnet)
        let reloaded = EnvelopeStore(service: service)
        XCTAssertThrowsError(try PaymentLinkFunder.beginFunding(record, walletId: record.walletId, store: reloaded, networkType: .mainnet))
        XCTAssertNotNil(reloaded.record(id: record.id, role: .sent)?.link)
    }

    @MainActor
    func testClaimedRecordsKeepRecoverySecretAcrossRestart() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .received)
        record.status = .claimed
        record.settleTxid = "mined-claim"
        try store.save(record)
        let reloaded = EnvelopeStore(service: service)
        let saved = try XCTUnwrap(reloaded.record(id: record.id, role: .received))
        XCTAssertNotNil(saved.link)
        let display = PaymentLinkDisplay(record: saved, fundingConfirmations: nil, daemonHeight: nil)
        // Settled: no Claim. Money left behind reopens it.
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: saved, display: display), [])
        XCTAssertEqual(EnvelopeStatusRules.status(for: obs(conf: 12, balance: 7, unlocked: 7, spends: ["mined-claim"], mined: ["mined-claim"]),
                                                  current: saved.status, role: .received, settleTxid: saved.settleTxid), .ready)
    }

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
        // The store numbers a new record ("Link 1").
        updated.number = 1
        XCTAssertEqual(reloaded.records, [updated])
        XCTAssertEqual(reloaded.record(id: record.id, role: .sent)?.link, vector)
        XCTAssertNil(reloaded.record(id: record.id, role: .received))

        reloaded.removeAll()
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

    // MARK: - Numbers and notes

    private func storeRecord(_ id: String, _ role: EnvelopeRecord.Role, createdAt: Date = Date(), note: String? = nil) -> EnvelopeRecord {
        var record = EnvelopeRecord(id: id, role: role, words: vectorWords, address: vectorAddress,
                                    restoreHeight: 150, amount: 100_000_000_000, expiry: 1_791_000_000,
                                    createdAt: createdAt, status: .created)
        record.note = note
        return record
    }

    @MainActor
    func testSentAndReceivedLinksShareOneCounter() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        XCTAssertEqual(store.nextNumber, 1)
        try store.save(storeRecord("a", .sent))
        try store.save(storeRecord("b", .received))
        try store.save(storeRecord("c", .sent))
        XCTAssertEqual(store.record(id: "a", role: .sent)?.number, 1)
        XCTAssertEqual(store.record(id: "b", role: .received)?.number, 2)
        XCTAssertEqual(store.record(id: "c", role: .sent)?.number, 3)

        // A caller's copy without the number keeps the stored number.
        var copy = storeRecord("a", .sent)
        copy.status = .pending
        try store.save(copy)
        XCTAssertEqual(store.record(id: "a", role: .sent)?.number, 1)
        XCTAssertEqual(store.record(id: "a", role: .sent)?.status, .pending)

        // Numbers carry on after a relaunch.
        let relaunched = EnvelopeStore(service: service)
        XCTAssertEqual(relaunched.nextNumber, 4)
        try relaunched.save(storeRecord("d", .received))
        XCTAssertEqual(relaunched.record(id: "d", role: .received)?.number, 4)

        // Remove All starts again at 1.
        relaunched.removeAll()
        XCTAssertEqual(EnvelopeStore(service: service).nextNumber, 1)
    }

    /// A record a missed check wrote Not funded over its funding reads
    /// Pending again when the store loads; its secret stays.
    @MainActor
    func testTheStoreLoadsAFundedLinkAsWaiting() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var funded = storeRecord("funded", .sent)
        funded.fundingTxid = "f"
        funded.status = .notFunded
        var unfunded = storeRecord("unfunded", .sent)
        unfunded.status = .notFunded
        var received = storeRecord("received", .received)
        received.status = .notFunded
        try store.save(funded)
        try store.save(unfunded)
        try store.save(received)

        let relaunched = EnvelopeStore(service: service)
        XCTAssertEqual(relaunched.record(id: "funded", role: .sent)?.status, .pending)
        XCTAssertNotNil(relaunched.record(id: "funded", role: .sent)?.link)
        // Never funded: kept, with its secret, as it was.
        XCTAssertEqual(relaunched.record(id: "unfunded", role: .sent)?.status, .notFunded)
        XCTAssertNotNil(relaunched.record(id: "unfunded", role: .sent)?.link)
        XCTAssertEqual(relaunched.record(id: "received", role: .received)?.status, .notFunded)
        // Written back, so the next launch reads it as it is.
        XCTAssertEqual(EnvelopeStore(service: service).record(id: "funded", role: .sent)?.status, .pending)
    }

    @MainActor
    func testRecordsFromBeforeNumbersGetThemOnceOldestFirst() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Written as an older build wrote them: no number, no note.
        for (id, role, offset) in [("new", EnvelopeRecord.Role.sent, 300.0), ("old", .received, 100), ("mid", .sent, 200)] {
            let data = try JSONEncoder().encode(storeRecord(id, role, createdAt: base.addingTimeInterval(offset)))
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains("number"))
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(role.rawValue).\(id)",
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        }
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        XCTAssertEqual(store.record(id: "old", role: .received)?.number, 1)
        XCTAssertEqual(store.record(id: "mid", role: .sent)?.number, 2)
        XCTAssertEqual(store.record(id: "new", role: .sent)?.number, 3)
        XCTAssertEqual(store.nextNumber, 4)

        // Saved: the next launch reads the same numbers.
        let relaunched = EnvelopeStore(service: service)
        XCTAssertEqual(relaunched.record(id: "old", role: .received)?.displayName, "Link 1")
        XCTAssertEqual(relaunched.record(id: "new", role: .sent)?.displayName, "Link 3")
        XCTAssertEqual(relaunched.nextNumber, 4)
    }

    @MainActor
    func testNoteNamesTheLinkAndOnlyARenameChangesIt() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        try store.save(storeRecord("a", .sent, note: "Dinner"))
        XCTAssertEqual(store.record(id: "a", role: .sent)?.displayName, "Dinner")

        // A copy taken before a rename cannot undo it.
        let stale = try XCTUnwrap(store.record(id: "a", role: .sent))
        try store.setNote("  Rent  ", id: "a", role: .sent)
        try store.save(stale)
        XCTAssertEqual(store.record(id: "a", role: .sent)?.note, "Rent")
        XCTAssertEqual(EnvelopeStore(service: service).record(id: "a", role: .sent)?.displayName, "Rent")

        // Clearing the note goes back to the number.
        try store.setNote("   ", id: "a", role: .sent)
        XCTAssertNil(store.record(id: "a", role: .sent)?.note)
        XCTAssertEqual(store.record(id: "a", role: .sent)?.displayName, "Link 1")
    }

    func testDisplayNameFallsBackToTheNumber() {
        XCTAssertEqual(EnvelopeRecord.displayName(note: "Dinner", number: 7), "Dinner")
        XCTAssertEqual(EnvelopeRecord.displayName(note: " Dinner\n", number: 7), "Dinner")
        XCTAssertEqual(EnvelopeRecord.displayName(note: "  ", number: 7), "Link 7")
        XCTAssertEqual(EnvelopeRecord.displayName(note: nil, number: 7), "Link 7")
        XCTAssertEqual(EnvelopeRecord.displayName(note: nil, number: nil), "Payment link")
    }

    @MainActor
    func testNoteNeverLeavesThisIPhone() throws {
        let note = "Rent for Sam"
        var record = storeRecord("0123456789abcdef", .sent, note: note)
        record.number = 7
        let url = try XCTUnwrap(record.link?.url)
        XCTAssertFalse(url.contains("Rent"))
        XCTAssertFalse(url.contains("Sam"))
        let share = try XCTUnwrap(PaymentLinkFunder.shareText(for: record))
        XCTAssertFalse(share.contains("Rent"))
        XCTAssertFalse(share.contains("Sam"))
        XCTAssertFalse(share.contains("Link 7"))
        XCTAssertEqual(PaymentLinkFunder.memo, "Payment link")
        // The link is the same with or without a note.
        record.note = nil
        XCTAssertEqual(record.link?.url, url)
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

    /// A v2 link shares the web link, its secret behind the directive.
    @MainActor
    func testV2ShareUsesTheWebLink() throws {
        let secret = [UInt8](0..<16)
        let link = try XCTUnwrap(EnvelopeLink(secret: secret, restoreHeight: 150))
        var record = EnvelopeRecord(id: link.id, role: .sent, words: nil, address: vectorAddress,
                                    restoreHeight: 150, amount: 1_000_000_000, expiry: 0,
                                    createdAt: Date(), status: .pending)
        record.setSecret(from: link)

        let item = try XCTUnwrap(PaymentLinkShareItem(record: record))
        XCTAssertEqual(item.url.absoluteString, "https://monero.one/c#2:~:m1=112drXXUifSrRnXLGbXg8E3b")
        XCTAssertEqual(item.text, "I sent you 0.0010 XMR. Tap to claim it in Monero One: https://monero.one/c#2:~:m1=112drXXUifSrRnXLGbXg8E3b")
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .message) as? URL, item.url)
        XCTAssertEqual(try EnvelopeLink.parse(item.url.absoluteString), link)
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
        // The long amount fits on one line of the envelope's foil.
        XCTAssertEqual(PaymentLinkCard.amount(12_345_678_901_200).text, "12.3456789012")
    }

    /// The card shrinks the amount first, then rounds it with "~", and
    /// never shows "XMR" alone.
    func testLinkCardShrinksThenRounds() {
        // 170 per character: 820 fits 4.8 characters, 40% fits 12.
        let width: (String) -> CGFloat = { CGFloat($0.count) * 170 }
        func card(_ piconero: UInt64) -> PaymentLinkCard.Amount {
            PaymentLinkCard.amount(piconero, width: width)
        }
        XCTAssertEqual(card(50_000_000_000), .init(text: "0.05", scale: 1))
        XCTAssertEqual(card(25_404_800_000).text, "0.0254048")
        XCTAssertEqual(card(25_404_800_000).scale, 820 / 1530, accuracy: 0.0001)
        XCTAssertEqual(card(12_345_678_901_200).text, "~12.35")
        XCTAssertEqual(card(123_456_789).text, "~0.00012")
        XCTAssertEqual(card(1_234_567_891_234_000_000).text, "~1,234,568")
        let tiny = card(1)
        XCTAssertEqual(tiny.text, "0.000000000001")
        XCTAssertLessThan(tiny.scale, PaymentLinkCard.minimumScale)
        XCTAssertGreaterThan(tiny.scale, 0)
    }

    // MARK: - Claim destination

    private func wallet(_ name: String, address: String?, balance: Decimal? = nil, source: WalletSource = .seed(.bip39)) -> WalletInfo {
        WalletInfo(id: UUID(), name: name, source: source, createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                   userCreatedSubaddressIndices: [], cachedPrimaryAddress: address, cachedBalance: balance)
    }

    private let valid: (String) -> Bool = { $0.hasPrefix("4") || $0.hasPrefix("8") }

    func testClaimDestinationsKeepWalletsWithAValidMainAddress() {
        let main = wallet("Main", address: "4main", balance: 1)
        let savings = wallet("Savings", address: "4savings", balance: 2)
        let viewOnly = wallet("Watch", address: "4watch", source: .viewOnly)
        let empty = wallet("New", address: nil)
        let blank = wallet("Blank", address: "  ")
        let nullKey = wallet("Burn", address: NullKeyAddress.mainnet)
        let otherNetwork = wallet("Testnet", address: "9testnet")
        let active = EnvelopeRuntime.Destination(address: "4mainlive", walletName: "Main", walletId: main.id)

        let list = PaymentLinkClaimDestinations.eligible(
            wallets: [main, savings, viewOnly, empty, blank, nullKey, otherNetwork],
            active: active,
            activeBalance: 5,
            isValidAddress: valid
        )
        // Wallet switcher order; view-only can receive; no saved address,
        // the null-key address and another network's address are left out.
        XCTAssertEqual(list.map(\.name), ["Main", "Savings", "Watch"])
        // Every wallet at its main address: the open one as the runtime read
        // it before the wallet stopped, a closed one as saved.
        XCTAssertEqual(list.map(\.address), ["4mainlive", "4savings", "4watch"])
        // The rows show the open wallet's live balance and the others' last
        // known one; unknown stays unknown.
        XCTAssertEqual(list.map(\.balance), [5, 2, nil])
        XCTAssertEqual(list.map(\.isOpen), [true, false, false])
        XCTAssertTrue(list[2].wallet.isViewOnly)
    }

    func testTheOpenWalletIsEligibleWithoutASavedAddress() {
        let main = wallet("Main", address: nil)
        let active = EnvelopeRuntime.Destination(address: "4mainlive", walletName: "Main", walletId: main.id)
        let list = PaymentLinkClaimDestinations.eligible(wallets: [main], active: active, activeBalance: nil, isValidAddress: valid)
        XCTAssertEqual(list.map(\.address), ["4mainlive"])
    }

    func testClaimGoesToTheOpenWalletByDefault() {
        let main = wallet("Main", address: "4main")
        let savings = wallet("Savings", address: "4savings")
        let list = PaymentLinkClaimDestinations.eligible(wallets: [main, savings], active: nil, activeBalance: nil, isValidAddress: valid)
        let choice = PaymentLinkClaimDestinations.defaultChoice(among: list, role: .received, fundingWalletId: main.id.uuidString, activeWalletId: savings.id)
        XCTAssertEqual(choice?.walletId, savings.id)
    }

    func testReclaimGoesToTheFundingWalletWhenItCanReceive() {
        let main = wallet("Main", address: "4main")
        let savings = wallet("Savings", address: "4savings")
        let list = PaymentLinkClaimDestinations.eligible(wallets: [main, savings], active: nil, activeBalance: nil, isValidAddress: valid)
        let funded = PaymentLinkClaimDestinations.defaultChoice(among: list, role: .sent, fundingWalletId: savings.id.uuidString, activeWalletId: main.id)
        XCTAssertEqual(funded?.walletId, savings.id)
        // Lowercase ids from another writer still match.
        let lower = PaymentLinkClaimDestinations.defaultChoice(among: list, role: .sent, fundingWalletId: savings.id.uuidString.lowercased(), activeWalletId: main.id)
        XCTAssertEqual(lower?.walletId, savings.id)
    }

    func testReclaimFallsBackToTheOpenWallet() {
        let main = wallet("Main", address: "4main")
        let removed = UUID()
        let noAddress = wallet("New", address: nil)
        let list = PaymentLinkClaimDestinations.eligible(wallets: [main, noAddress], active: nil, activeBalance: nil, isValidAddress: valid)
        // An old record with no funding wallet.
        XCTAssertEqual(PaymentLinkClaimDestinations.defaultChoice(among: list, role: .sent, fundingWalletId: nil, activeWalletId: main.id)?.walletId, main.id)
        // The funding wallet was removed.
        XCTAssertEqual(PaymentLinkClaimDestinations.defaultChoice(among: list, role: .sent, fundingWalletId: removed.uuidString, activeWalletId: main.id)?.walletId, main.id)
        // The funding wallet has no address to receive at.
        XCTAssertEqual(PaymentLinkClaimDestinations.defaultChoice(among: list, role: .sent, fundingWalletId: noAddress.id.uuidString, activeWalletId: main.id)?.walletId, main.id)
        // Never another wallet when the open one is not in the list.
        XCTAssertNil(PaymentLinkClaimDestinations.defaultChoice(among: list, role: .received, fundingWalletId: nil, activeWalletId: UUID()))
    }

    func testTheClaimRowReadsTheWalletAndItsKind() {
        XCTAssertEqual(EnvelopeSessionContent.spokenDestination(title: "Claim to", wallet: wallet("Savings", address: "4s")), "Claim to, Savings")
        XCTAssertEqual(EnvelopeSessionContent.spokenDestination(title: "Claim to", wallet: wallet("Watch", address: "4w", source: .viewOnly)), "Claim to, Watch, view-only")
    }

    // MARK: - Stuck states

    private func outgoing(_ id: String, _ status: MoneroTransaction.TransactionStatus, at seconds: TimeInterval = 0,
                          height: UInt64? = nil, to address: String? = nil) -> MoneroTransaction {
        MoneroTransaction(id: id, type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(timeIntervalSince1970: seconds),
                          confirmations: status == .confirmed ? 4 : 0, status: status, memo: nil, blockHeight: height,
                          destinations: address.map { [MoneroTransactionDestination(address: $0, amount: 1)] } ?? [])
    }

    /// The funding's txids are saved before the broadcast. A send that timed
    /// out (the node took it, the app never heard back) stays hidden, then
    /// shows as Waiting once the history or a scan has one of them: after a
    /// restart, in a wallet restored from its seed, with no time limit.
    @MainActor
    func testASavedFundingAttemptIsAdoptedByItsTxid() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .sent)
        record.walletId = "funding-wallet"
        record.expiry = Int64(Date().timeIntervalSince1970) + 86_400
        try PaymentLinkFunder.save(record, store: store, networkType: .mainnet)
        // No txids without the funding lock.
        XCTAssertThrowsError(try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["f1"], store: store))
        try PaymentLinkFunder.beginFunding(record, walletId: record.walletId, store: store, networkType: .mainnet)
        try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["f1", "f2"], store: store)
        // One attempt per link: a second signed funding is never broadcast.
        XCTAssertThrowsError(try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["g1"], store: store))
        // The broadcast timed out: hidden, and its envelope is scanned.
        PaymentLinkFunder.markNotFunded(id: record.id, store: store)
        let hidden = try XCTUnwrap(store.record(id: record.id, role: .sent))
        XCTAssertEqual(hidden.attemptTxids, ["f1", "f2"])
        XCTAssertNil(hidden.knownFundingTxid)
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(hidden, activeWalletId: "funding-wallet"))
        XCTAssertTrue(EnvelopeStatusRules.needsFundingScan(hidden, now: Date()))
        // A stale copy cannot erase the saved txids.
        try store.save(record)
        XCTAssertEqual(store.record(id: record.id, role: .sent)?.attemptTxids, ["f1", "f2"])

        // Relaunch, then a seed restore: the wallet has a new id, and its
        // history shows the second transaction of the split funding, long after.
        let relaunched = try XCTUnwrap(EnvelopeStore(service: service).record(id: record.id, role: .sent))
        XCTAssertEqual(relaunched.attemptTxids, ["f1", "f2"])
        let mined = outgoing("f2", .confirmed, height: 2_000)
        let found = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(
            sent: [relaunched], activeWalletId: "restored", walletIds: ["restored"], transactions: [mined]).first)
        XCTAssertEqual(found.fundingTxid, "f2")
        XCTAssertEqual(found.status, .pending)
        XCTAssertEqual(found.fundingHeight, 2_000)
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(found, activeWalletId: "restored", walletIds: ["restored"]))
        let display = PaymentLinkDisplay(record: found, fundingConfirmations: nil, daemonHeight: nil)
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: found, display: display), [.share, .reclaim])
        // The txid is the link's own: any wallet's history adopts it.
        XCTAssertEqual(PaymentLinksStatusChecker.fundingUpdates(
            sent: [relaunched], activeWalletId: "w2", walletIds: ["w2", "funding-wallet"], transactions: [mined]).first?.fundingTxid, "f2")

        // A scan finds it first: the attempt's txid wins over an older deposit.
        var scan = obs(conf: 3, balance: 7)
        scan.fundingTxids = ["someone-else", "f1"]
        let scanned = PaymentLinksStatusChecker.applying(scan, to: relaunched, transactions: [], now: Date()).record
        XCTAssertEqual(scanned.fundingTxid, "f1")
        XCTAssertEqual(scanned.status, .pending)
    }

    /// A funding the wallet marks failed after the send (gone from the pool
    /// unmined): the link hides again (no Share, no count) and keeps its
    /// secret. It shows as Waiting once the funding is live or a scan sees it.
    func testAFailedFundingHidesTheLinkUntilItIsSeen() throws {
        var record = storeRecord(vector.id, .sent)
        record.walletId = "w1"
        record.fundingStartedAt = Date().addingTimeInterval(-3_600)
        record.fundingTxid = "f"
        record.status = .pending
        let failed = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(
            sent: [record], activeWalletId: "w1", transactions: [outgoing("f", .failed, to: record.address)]).first)
        XCTAssertEqual(failed.fundingFailed, true)
        XCTAssertEqual(failed.status, .notFunded)
        XCTAssertNil(failed.knownFundingTxid)
        XCTAssertNotNil(failed.link)
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(failed, activeWalletId: "w1"))
        XCTAssertTrue(OpenPaymentLinks.summary(of: [failed], activeWalletId: "w1").isEmpty)
        let display = PaymentLinkDisplay(record: failed, fundingConfirmations: nil, daemonHeight: nil)
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: failed, display: display), [])
        // Its envelope is scanned for the funding; the next history read changes nothing.
        XCTAssertTrue(EnvelopeStatusRules.needsFundingScan(failed, now: Date()))
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(
            sent: [failed], activeWalletId: "w1", transactions: [outgoing("f", .failed, to: record.address)]).isEmpty)

        // Live again in the history: Waiting.
        let live = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(
            sent: [failed], activeWalletId: "w1", transactions: [outgoing("f", .pending, to: record.address)]).first)
        XCTAssertNil(live.fundingFailed)
        XCTAssertEqual(live.status, .pending)
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(live, activeWalletId: "w1"))
        // Or a scan sees the money.
        var seen = obs(conf: 2, balance: 7)
        seen.fundingTxids = ["f"]
        let scanned = PaymentLinksStatusChecker.applying(seen, to: failed, transactions: [], now: Date()).record
        XCTAssertNil(scanned.fundingFailed)
        XCTAssertEqual(scanned.status, .pending)
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(scanned, activeWalletId: "w1"))
    }

    /// The settle's grace counts blocks: dropped only once the scan is more
    /// than 30 blocks past the settle's height. The clock (60 minutes)
    /// counts only when no height is known.
    func testTheSettleGraceCountsBlocks() {
        let rules = EnvelopeStatusRules.self
        let now = Date()
        let longAgo = now.addingTimeInterval(-2 * rules.settleGrace)
        XCTAssertEqual(rules.settleGraceBlocks, 30)
        XCTAssertFalse(rules.settleGraceIsOver(settledAt: longAgo, settleHeight: 1_000, scanHeight: 1_030, now: now))
        XCTAssertTrue(rules.settleGraceIsOver(settledAt: now, settleHeight: 1_000, scanHeight: 1_031, now: now))
        // No height: the clock.
        XCTAssertTrue(rules.settleGraceIsOver(settledAt: longAgo, settleHeight: nil, scanHeight: 1_031, now: now))
        XCTAssertTrue(rules.settleGraceIsOver(settledAt: longAgo, settleHeight: 1_000, scanHeight: 0, now: now))
        XCTAssertFalse(rules.settleGraceIsOver(settledAt: now.addingTimeInterval(-(rules.settleGrace - 60)), settleHeight: nil, scanHeight: 0, now: now))
        XCTAssertFalse(rules.settleGraceIsOver(settledAt: nil, settleHeight: nil, scanHeight: 1_031, now: now))

        // A claim that never went out (the app quit before the broadcast)
        // opens the link again 31 blocks later.
        var claim = storeRecord("0123456789abcdef", .received)
        claim.settle(txids: ["never-sent"], amount: 7, walletName: "Main", height: 1_000, leftLocked: false, at: now)
        var inside = obs(conf: 30, balance: 7, unlocked: 7)
        inside.height = 1_030
        XCTAssertEqual(PaymentLinksStatusChecker.applying(inside, to: claim, transactions: [], now: now.addingTimeInterval(7_200)).record.status, .claimed)
        var past = inside
        past.height = 1_031
        let reopened = PaymentLinksStatusChecker.applying(past, to: claim, transactions: [], now: now).record
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertNil(reopened.settleTxid)
        XCTAssertNil(reopened.settleHeight)
        XCTAssertEqual(reopened.spendsBeforeSettle, ["never-sent"])
    }

    /// The sweep is saved as the link's settle before its broadcast. An app
    /// kill after it leaves the link settled, never claimable twice; a sweep
    /// the node refused puts the link back as it was.
    @MainActor
    func testAKillBetweenSweepAndSaveLeavesTheLinkSettled() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        let now = Date()
        var before = storeRecord(vector.id, .received)
        before.status = .ready
        try store.save(before)
        let attempt = EnvelopeRuntime.SweepAttempt(txids: ["s1", "s2"], amount: 9, height: 2_000, leavesLocked: false)
        try store.save(EnvelopeSession.settling(before, attempt: attempt, walletName: "Main", now: now))

        // Killed here. Relaunch:
        let settled = try XCTUnwrap(EnvelopeStore(service: service).record(id: before.id, role: .received))
        XCTAssertEqual(settled.status, .claimed)
        XCTAssertEqual(settled.settleTxid, "s1")
        XCTAssertEqual(settled.settleTxids, ["s1", "s2"])
        XCTAssertEqual(settled.settledAmount, 9)
        XCTAssertEqual(settled.settleHeight, 2_000)
        XCTAssertEqual(settled.ownSettleTxids, ["s1", "s2"])
        XCTAssertFalse(OpenPaymentLinks.isToClaim(settled))
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: settled, display: PaymentLinkDisplay(record: settled, fundingConfirmations: nil, daemonHeight: nil)), [])
        // A look tells whether it went out.
        XCTAssertTrue(OpenPaymentLinks.needsLook(settled, activeWalletId: "w1", transactions: [], now: now))

        // The commit's error decides what the record keeps.
        typealias Failure = EnvelopeRuntime.RuntimeError
        XCTAssertNil(EnvelopeSession.afterFailedSweep(settled, before: before, error: Failure.sweepUnconfirmed("x")))
        let refused = try XCTUnwrap(EnvelopeSession.afterFailedSweep(settled, before: before, error: Failure.sweepFailed("x")))
        XCTAssertEqual(refused.status, .ready)
        XCTAssertNil(refused.settleTxid)
        XCTAssertNil(refused.settleHeight)
        let lost = try XCTUnwrap(EnvelopeSession.afterFailedSweep(settled, before: before, error: Failure.alreadyClaimed))
        XCTAssertEqual(lost.status, .claimed)
        XCTAssertNil(lost.settleTxid)
        // Failed before anything was saved: nothing to undo.
        XCTAssertNil(EnvelopeSession.afterFailedSweep(before, before: before, error: Failure.sweepFailed("x")))

        // Which commit errors may hide a sweep that went out.
        func mapped(_ error: Error) -> Failure? { EnvelopeRuntime.mapSweepError(error) as? Failure }
        XCTAssertEqual(mapped(MoneroWallet.BroadcastCancelled(underlying: Failure.walletBusy)), .sweepFailed(Failure.walletBusy.localizedDescription))
        XCTAssertEqual(mapped(MoneroCoreError.transactionCommitFailed("double spend")), .alreadyClaimed)
        if case .sweepFailed = mapped(MoneroCoreError.transactionCommitFailed("transaction was rejected by daemon")) {} else { XCTFail("refused") }
        if case .sweepFailed = mapped(MoneroCoreError.transactionCommitFailed("daemon is busy")) {} else { XCTFail("busy") }
        if case .sweepUnconfirmed = mapped(MoneroCoreError.transactionCommitFailed("no connection to daemon")) {} else { XCTFail("no answer") }
        if case .sweepUnconfirmed = mapped(MoneroCoreError.transactionCommitFailed("Unknown exception")) {} else { XCTFail("unknown") }
    }

    /// A sweep that left newer, still locked money in the envelope keeps
    /// the link looked at until that money unlocks (the link opens again)
    /// or a look sees none left.
    func testASettleThatLeftLockedMoneyKeepsLooking() {
        let now = Date()
        var claim = storeRecord("0123456789abcdef", .received)
        claim.settle(txids: ["c1"], amount: 5, walletName: "Main", height: 1_000, leftLocked: true, at: now)
        XCTAssertEqual(claim.settleLeftLocked, true)
        XCTAssertTrue(EnvelopeStatusRules.needsSettleLook(claim, transactions: []))
        // Not while our claim waits in this wallet's pool.
        XCTAssertFalse(EnvelopeStatusRules.needsSettleLook(claim, transactions: [history("c1", .pending)]))

        // Mined, the newer money still locked: settled, and the looks go on.
        let locked = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 7, unlocked: 0, spends: ["c1"], mined: ["c1"]),
                                                        to: claim, transactions: [history("c1", .confirmed)], now: now)
        XCTAssertEqual(locked.record.status, .claimed)
        XCTAssertFalse(locked.conclusive)
        XCTAssertEqual(locked.record.settleSeenMined, true)
        XCTAssertEqual(locked.record.settleLeftLocked, true)
        XCTAssertTrue(EnvelopeStatusRules.needsSettleLook(locked.record, transactions: [history("c1", .confirmed)]))

        // Unlocked: Ready to claim again.
        let open = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 7, unlocked: 7, spends: ["c1"], mined: ["c1"]),
                                                      to: locked.record, transactions: [], now: now)
        XCTAssertEqual(open.record.status, .ready)
        XCTAssertTrue(open.conclusive)
        XCTAssertNil(open.record.settleTxid)
        XCTAssertNil(open.record.settleLeftLocked)
        XCTAssertEqual(open.record.spendsBeforeSettle, ["c1"])
        XCTAssertTrue(OpenPaymentLinks.isToClaim(open.record))

        // Or the money left: settled for good, no more looks.
        let empty = PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["c1", "other"], mined: ["c1", "other"]),
                                                       to: locked.record, transactions: [], now: now)
        XCTAssertEqual(empty.record.status, .claimed)
        XCTAssertTrue(empty.conclusive)
        XCTAssertNil(empty.record.settleLeftLocked)
        XCTAssertFalse(EnvelopeStatusRules.needsSettleLook(empty.record, transactions: []))
    }

    /// Two devices claim one link. Ours lost (a double spend): the envelope
    /// is empty and another claim is in a block. The link reads "Already
    /// claimed", and no look follows.
    func testAClaimThatLostToAnotherDeviceReadsAlreadyClaimed() {
        let now = Date()
        var claim = storeRecord("0123456789abcdef", .received)
        claim.settle(txids: ["ours"], amount: 7, walletName: "Main", height: 1_000, leftLocked: false, at: now)
        func beaten(_ observation: EnvelopeObservation, role: EnvelopeRecord.Role = .received) -> Bool {
            EnvelopeStatusRules.claimWasBeaten(role: role, settleTxid: "ours", settleTxids: ["ours"], spendsBeforeSettle: [],
                                               ownSettleTxids: ["ours"], observation: observation)
        }
        XCTAssertTrue(beaten(obs(conf: 30, spends: ["theirs"], mined: ["theirs"])))
        // Theirs only in the pool, ours seen, money left, or a sent link: not beaten.
        XCTAssertFalse(beaten(obs(conf: 30, spends: ["theirs"])))
        XCTAssertFalse(beaten(obs(conf: 30, spends: ["theirs", "ours"], mined: ["theirs"])))
        XCTAssertFalse(beaten(obs(conf: 30, balance: 7, unlocked: 7, spends: ["theirs"], mined: ["theirs"])))
        XCTAssertFalse(beaten(obs(conf: 30, spends: ["theirs"], mined: ["theirs"]), role: .sent))

        let lost = PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["theirs"], mined: ["theirs"]), to: claim, transactions: [], now: now)
        XCTAssertEqual(lost.record.status, .claimed)
        XCTAssertTrue(lost.conclusive)
        XCTAssertNil(lost.record.settleTxid)
        XCTAssertNil(lost.record.settledAmount)
        XCTAssertNil(lost.record.walletName)
        XCTAssertEqual(lost.record.ownSettleTxids, ["ours"])
        XCTAssertEqual(PaymentLinkDisplay(record: lost.record, fundingConfirmations: nil, daemonHeight: nil).label, "Already claimed")
        XCTAssertFalse(EnvelopeStatusRules.needsSettleLook(lost.record, transactions: []))
        XCTAssertFalse(OpenPaymentLinks.needsLook(lost.record, activeWalletId: "w1", transactions: [], now: now))
    }

    /// Our claim read as dropped, the link opened again, then the claim was
    /// mined after all: the link reads Claimed by us, with its amount and
    /// wallet, never "Already claimed".
    func testALateMinedClaimOfOursIsOursAgain() {
        let now = Date()
        var claim = storeRecord("0123456789abcdef", .received)
        claim.settle(txids: ["slow"], amount: 7, walletName: "Main", height: nil, leftLocked: false,
                     at: now.addingTimeInterval(-2 * EnvelopeStatusRules.settleGrace))
        let reopened = PaymentLinksStatusChecker.applying(obs(conf: 30, balance: 8, unlocked: 8), to: claim, transactions: [], now: now).record
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertNil(reopened.settleTxid)
        let mined = PaymentLinksStatusChecker.applying(obs(conf: 40, spends: ["slow"], mined: ["slow"]), to: reopened, transactions: [], now: now)
        XCTAssertEqual(mined.record.status, .claimed)
        XCTAssertEqual(mined.record.settleTxid, "slow")
        XCTAssertEqual(mined.record.settledAmount, 7)
        XCTAssertEqual(mined.record.walletName, "Main")
        XCTAssertEqual(mined.record.settleSeenMined, true)
        XCTAssertEqual(PaymentLinkDisplay(record: mined.record, fundingConfirmations: nil, daemonHeight: nil).label, "Claimed")
        // A claim made elsewhere: Already claimed.
        let theirs = PaymentLinksStatusChecker.applying(obs(conf: 40, spends: ["theirs"], mined: ["theirs"]), to: reopened, transactions: [], now: now)
        XCTAssertEqual(theirs.record.status, .claimed)
        XCTAssertNil(theirs.record.settleTxid)
        XCTAssertEqual(PaymentLinkDisplay(record: theirs.record, fundingConfirmations: nil, daemonHeight: nil).label, "Already claimed")
    }

    /// A reclaim that split into two transactions: both are ours. A scan
    /// that sees only the second never reads it as a claim that beat ours,
    /// and every txid we sent stays ours across a reopen and a stale save.
    @MainActor
    func testEveryTransactionOfASplitSweepIsOurs() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        let now = Date()
        var sent = storeRecord(vector.id, .sent)
        sent.walletId = "w1"
        sent.fundingTxid = "funding"
        sent.status = .ready
        let stale = sent
        sent.settle(txids: ["r1", "r2"], amount: 9, walletName: "Main", height: 1_000, leftLocked: false, at: now)
        try store.save(sent)
        try store.save(stale)
        XCTAssertEqual(store.record(id: sent.id, role: .sent)?.ownSettleTxids, ["r1", "r2"])

        let second = PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["r2"], mined: ["r2"]), to: sent, transactions: [], now: now)
        XCTAssertEqual(second.record.status, .reclaimed)
        XCTAssertFalse(second.conclusive)
        let both = PaymentLinksStatusChecker.applying(obs(conf: 30, spends: ["r1", "r2"], mined: ["r1", "r2"]), to: sent, transactions: [], now: now)
        XCTAssertEqual(both.record.status, .reclaimed)
        XCTAssertTrue(both.conclusive)
        XCTAssertEqual(both.record.settleSeenMined, true)
        // Reopened by a top-up, then emptied by our split reclaim: Reclaimed.
        var reopened = sent
        reopened.reopen()
        XCTAssertEqual(reopened.spendsBeforeSettle, ["r1", "r2"])
        reopened.status = .ready
        XCTAssertEqual(EnvelopeStatusRules.status(for: obs(conf: 30, spends: ["r1", "r2"], mined: ["r1", "r2"]), current: .ready,
                                                  role: .sent, ownSettleTxids: reopened.ownSettleTxids), .reclaimed)
    }

    /// A hardware link funding: the step that saves the txids before the
    /// broadcast stays for every run of the session sheet, and the sheet
    /// offers no Try Again for it. A second signed funding meets the link's
    /// one attempt and is never broadcast.
    @MainActor
    func testAHardwareLinkFundingNeverBroadcastsTwice() throws {
        let envelope = "4envelope"
        let step = WalletManager.PendingBroadcastStep(address: envelope, run: { _ in })
        XCTAssertNotNil(WalletManager.broadcastStep(step, for: envelope))
        // Still there for a second run.
        XCTAssertNotNil(WalletManager.broadcastStep(step, for: envelope))
        XCTAssertNil(WalletManager.broadcastStep(step, for: "4other"))
        XCTAssertNil(WalletManager.broadcastStep(nil, for: envelope))

        typealias Sheet = HardwareSessionSheet
        XCTAssertFalse(Sheet.offersTryAgain(intent: .send(to: envelope, amount: 1, memo: nil), linkFundingAddress: envelope))
        XCTAssertFalse(Sheet.offersTryAgain(intent: .sendAll(to: envelope, memo: nil), linkFundingAddress: envelope))
        // A normal send keeps its Try Again.
        XCTAssertTrue(Sheet.offersTryAgain(intent: .send(to: "4other", amount: 1, memo: nil), linkFundingAddress: envelope))
        XCTAssertTrue(Sheet.offersTryAgain(intent: .send(to: envelope, amount: 1, memo: nil), linkFundingAddress: nil))
        XCTAssertTrue(Sheet.offersTryAgain(intent: .syncSentTransactions, linkFundingAddress: envelope))

        // What the step saves: one attempt per link.
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .sent)
        record.walletId = "trezor"
        try PaymentLinkFunder.beginFunding(record, walletId: "trezor", store: store, networkType: .mainnet)
        try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["first"], store: store)
        XCTAssertThrowsError(try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["second"], store: store))
        XCTAssertEqual(store.record(id: record.id, role: .sent)?.attemptTxids, ["first"])
        XCTAssertThrowsError(try PaymentLinkFunder.beginFunding(record, walletId: "trezor", store: store, networkType: .mainnet))
    }

    /// A claim or reclaim the active wallet's history shows mined needs no
    /// look from any wallet after it: a switch to another wallet does not
    /// stop the active wallet to look at long-settled links. A sweep still
    /// waiting, a split one not all mined, or one that left money locked
    /// keeps its looks.
    func testAMinedSettleInTheHistoryEndsItsLooks() {
        let now = Date()
        var claim = storeRecord(vector.id, .received)
        claim.settle(txids: ["c1"], amount: 5, walletName: "Main", height: 1_000, leftLocked: false, at: now)
        // The other wallet's history has no trace of it: a look.
        XCTAssertTrue(EnvelopeStatusRules.needsSettleLook(claim, transactions: []))

        let checker = PaymentLinksStatusChecker.self
        XCTAssertTrue(checker.settleUpdates(records: [claim], transactions: [history("c1", .pending)]).isEmpty)
        XCTAssertTrue(checker.settleUpdates(records: [claim], transactions: [history("c1", .failed)]).isEmpty)
        let marked = checker.settleUpdates(records: [claim], transactions: [history("c1", .confirmed)])
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.settleSeenMined, true)
        // Then, from any wallet: no look.
        XCTAssertFalse(EnvelopeStatusRules.needsSettleLook(marked[0], transactions: []))
        // Marked once only.
        XCTAssertTrue(checker.settleUpdates(records: marked, transactions: [history("c1", .confirmed)]).isEmpty)

        // A split reclaim: every transaction of it in a block.
        var sent = storeRecord(vector.id, .sent)
        sent.settle(txids: ["r1", "r2"], amount: 9, walletName: "Main", height: 1_000, leftLocked: false, at: now)
        XCTAssertTrue(checker.settleUpdates(records: [sent], transactions: [history("r1", .confirmed)]).isEmpty)
        XCTAssertEqual(checker.settleUpdates(records: [sent], transactions: [history("r1", .confirmed), history("r2", .confirmed)]).count, 1)

        // Money left locked at the sweep (a second funding): looks go on.
        var locked = storeRecord(vector.id, .received)
        locked.settle(txids: ["c2"], amount: 5, walletName: "Main", height: 1_000, leftLocked: true, at: now)
        let lockedMarked = checker.settleUpdates(records: [locked], transactions: [history("c2", .confirmed)])
        XCTAssertTrue(EnvelopeStatusRules.needsSettleLook(lockedMarked.first ?? locked, transactions: []))

        // An open link is not touched.
        var open = storeRecord(vector.id, .sent)
        XCTAssertTrue(checker.settleUpdates(records: [open], transactions: [history("c1", .confirmed)]).isEmpty)
    }

    /// A Trezor session and the payment-link checks never share MoneroKit's
    /// one wallet slot: while the session holds the runtime, no lease or
    /// check starts, and the active wallet is never stopped for one.
    @MainActor
    func testATrezorSessionKeepsLinkChecksOut() async {
        let runtime = EnvelopeRuntime.shared
        // Locked, so a lease outside a session fails with noDestination.
        let walletManager = WalletManager()
        await runtime.beginHardwareSession()
        XCTAssertTrue(runtime.hardwareSessionHolds)
        do {
            try await runtime.acquire(walletManager)
            XCTFail("a lease started during a Trezor session")
        } catch {
            XCTAssertEqual(error as? EnvelopeRuntime.RuntimeError, .walletBusy)
        }
        do {
            _ = try await runtime.check(link: vector, address: vectorAddress)
            XCTFail("a check ran during a Trezor session")
        } catch {
            XCTAssertEqual(error as? EnvelopeRuntime.RuntimeError, .walletBusy)
        }
        runtime.endHardwareSession()
        XCTAssertFalse(runtime.hardwareSessionHolds)
    }

    /// While Send is open no link check takes the active wallet: a lease
    /// and a check both refuse, and giving the wallet back with no check
    /// running returns at once.
    @MainActor
    func testSendKeepsLinkChecksOut() async {
        let runtime = EnvelopeRuntime.shared
        let walletManager = WalletManager()
        runtime.beginSend()
        XCTAssertTrue(runtime.sendHolds)
        do {
            try await runtime.acquire(walletManager)
            XCTFail("a lease started while Send was open")
        } catch {
            XCTAssertEqual(error as? EnvelopeRuntime.RuntimeError, .walletBusy)
        }
        do {
            _ = try await runtime.check(link: vector, address: vectorAddress)
            XCTFail("a check ran while Send was open")
        } catch {
            XCTAssertEqual(error as? EnvelopeRuntime.RuntimeError, .walletBusy)
        }
        await runtime.returnWalletForSend()
        XCTAssertFalse(runtime.holdsActiveWallet)
        runtime.endSend()
        XCTAssertFalse(runtime.sendHolds)
    }

    /// Review builds only on a synced wallet: "Synced" held through a
    /// restart, a scan or a node with no height yet keeps it waiting.
    func testReviewWaitsForASyncedWallet() {
        typealias Rules = SendWaitRules
        XCTAssertTrue(Rules.isReady(walletRunning: true, walletState: .synced, daemonHeight: 100, syncBlocked: false))
        XCTAssertFalse(Rules.isReady(walletRunning: true, walletState: .syncing(progress: 0.6, remaining: 40), daemonHeight: 100, syncBlocked: false))
        XCTAssertFalse(Rules.isReady(walletRunning: true, walletState: .connecting, daemonHeight: 100, syncBlocked: false))
        XCTAssertFalse(Rules.isReady(walletRunning: true, walletState: .synced, daemonHeight: 0, syncBlocked: false))
        XCTAssertFalse(Rules.isReady(walletRunning: false, walletState: .synced, daemonHeight: 100, syncBlocked: false))
        XCTAssertFalse(Rules.isReady(walletRunning: true, walletState: .synced, daemonHeight: 100, syncBlocked: true))

        XCTAssertEqual(Rules.stage(walletState: .synced, daemonHeight: 100), .synced)
        XCTAssertEqual(Rules.stage(walletState: .synced, daemonHeight: 0), .connecting)
        XCTAssertEqual(Rules.stage(walletState: .syncing(progress: 50, remaining: 5), daemonHeight: 100), .syncing)
        XCTAssertEqual(Rules.stage(walletState: .connecting, daemonHeight: 0), .connecting)
        // A restarting or failing wallet with heights from before the restart
        // is still connecting, never "Scanning...".
        XCTAssertEqual(Rules.stage(walletState: .connecting, daemonHeight: 100), .connecting)
        XCTAssertEqual(Rules.stage(walletState: .idle, daemonHeight: 100), .connecting)
        XCTAssertEqual(Rules.stage(walletState: .error("node down"), daemonHeight: 100), .connecting)
    }

    /// The slot shows a real failure at once and a wait only after its
    /// delay. Only a failure the user can fix by trying again offers Retry.
    func testSendWaitSlotAndRetry() {
        typealias Rules = SendWaitRules
        XCTAssertEqual(Rules.slot(failure: nil, failureCanRetry: false, isWaitShown: false, isConnected: false, syncBlocked: false, syncFailed: false), .none)
        XCTAssertEqual(Rules.slot(failure: "x", failureCanRetry: true, isWaitShown: false, isConnected: true, syncBlocked: false, syncFailed: false), .failed("x", canRetry: true))
        XCTAssertEqual(Rules.slot(failure: nil, failureCanRetry: false, isWaitShown: true, isConnected: false, syncBlocked: true, syncFailed: true), .offline)
        XCTAssertEqual(Rules.slot(failure: nil, failureCanRetry: false, isWaitShown: true, isConnected: true, syncBlocked: true, syncFailed: false), .paused)
        XCTAssertEqual(Rules.slot(failure: nil, failureCanRetry: false, isWaitShown: true, isConnected: true, syncBlocked: false, syncFailed: true), .nodeUnreachable)
        XCTAssertEqual(Rules.slot(failure: nil, failureCanRetry: false, isWaitShown: true, isConnected: true, syncBlocked: false, syncFailed: false), .progress)

        XCTAssertFalse(Rules.canRetry(after: MoneroCoreError.insufficientFunds("1")))
        XCTAssertFalse(Rules.canRetry(after: PaymentLinkFunder.FundingError.insufficientFunds))
        XCTAssertTrue(Rules.canRetry(after: MoneroCoreError.transactionSendFailed("daemon busy")))
        XCTAssertTrue(Rules.canRetry(after: PaymentLinkFunder.FundingError.notSynced))
    }

    /// The gate keeps waiting while no wallet runs and stops when Review
    /// goes away.
    @MainActor
    func testTheSendGateWaitsUntilCancelled() async {
        let walletManager = WalletManager()
        let gate = Task { try await walletManager.awaitReadyToSend() }
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(walletManager.isReadyToSend)
        gate.cancel()
        do {
            try await gate.value
            XCTFail("the gate returned with no wallet running")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Cancel ends a Trezor session for real: a new session waits for the
    /// cancelled one to wind down instead of running beside it, a running
    /// one rejects a duplicate, and a finished one's result on screen
    /// rejects the fresh sheet instance that asks again.
    @MainActor
    func testACancelledTrezorSessionIsWaitedFor() {
        typealias Manager = WalletManager
        XCTAssertEqual(Manager.hardwareSessionStart(running: false, cancelled: false, state: .idle), .start)
        XCTAssertEqual(Manager.hardwareSessionStart(running: true, cancelled: false, state: .syncingFull(progress: 0, blocksRemaining: nil)), .reject)
        // Cancel set the state to idle while the session still runs.
        XCTAssertEqual(Manager.hardwareSessionStart(running: true, cancelled: false, state: .idle), .reject)
        XCTAssertEqual(Manager.hardwareSessionStart(running: true, cancelled: true, state: .idle), .waitForCancelled)
        XCTAssertEqual(Manager.hardwareSessionStart(running: false, cancelled: false, state: .complete(message: "")), .reject)
        XCTAssertEqual(Manager.hardwareSessionStart(running: false, cancelled: false, state: .failed(message: "")), .reject)

        // Cancel with no session running only clears the state.
        let walletManager = WalletManager()
        walletManager.cancelHardwareSession()
        XCTAssertEqual(walletManager.hardwareSessionState, .idle)
        XCTAssertFalse(walletManager.hardwareSessionRunning)
    }

    /// A hardware link funding reads as the link's in Activity as soon as
    /// the node takes it. The session marks the link funded itself: the
    /// view wallet's restart rebuilds the screens, so the Send flow's
    /// sheet-dismiss handler can come late or never run.
    @MainActor
    func testAHardwareLinkFundingIsLabeledAtBroadcast() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        var record = storeRecord(vector.id, .sent)
        record.walletId = "trezor"
        try PaymentLinkFunder.beginFunding(record, walletId: "trezor", store: store, networkType: .mainnet)
        let step = PaymentLinkFunder.hardwareStep(id: record.id, address: record.address, store: store)
        // What `step.run` saves before the broadcast.
        try PaymentLinkFunder.saveAttempt(id: record.id, txids: ["first"], store: store)
        // Saved attempts alone do not label the row.
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "first", isIncoming: false, records: store.records))

        XCTAssertNil(WalletManager.broadcastDone(step, for: "4other"))
        XCTAssertNil(WalletManager.broadcastDone(nil, for: record.address))
        let done = try XCTUnwrap(WalletManager.broadcastDone(step, for: record.address))
        done("first")
        let funded = try XCTUnwrap(store.record(id: record.id, role: .sent))
        XCTAssertEqual(funded.fundingTxid, "first")
        XCTAssertEqual(funded.status, .pending)
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "first", isIncoming: false, records: store.records)?.kind, .funding)
    }

    /// Send broadcasts only a funding that pays this link's envelope its
    /// amount plus the claim fee reserve.
    func testOnlyAFundingOfThisLinkGoesOut() {
        func matches(_ address: String, _ amount: UInt64, envelope: String = "4env") -> Bool {
            PaymentLinkFunder.fundingMatches(address: address, amount: amount, envelope: envelope, linkAmount: 100, feeReserve: 7)
        }
        XCTAssertTrue(matches("4env", 107))
        XCTAssertFalse(matches("4other", 107))
        XCTAssertFalse(matches("4env", 100))
        XCTAssertFalse(matches("4env", 108))
        XCTAssertFalse(matches("", 107, envelope: ""))
    }

    /// Our reclaim read as dropped (unseen 31 blocks), the link opened
    /// again, and a new reclaim lost as a double spend: the spend that won
    /// can be our first reclaim. The link reads Reclaimed, never Claimed,
    /// until a scan shows a claim made elsewhere.
    func testANewReclaimThatLostToOurEarlierOneReadsReclaimed() throws {
        typealias Failure = EnvelopeRuntime.RuntimeError
        let now = Date()
        var sent = storeRecord(vector.id, .sent)
        sent.walletId = "w1"
        sent.expiry = Int64(now.timeIntervalSince1970) + 86_400
        sent.fundingTxid = "funding"
        sent.status = .ready
        let neverReclaimed = sent
        sent.settle(txids: ["r1"], amount: 9, walletName: "Main", height: 1_000, leftLocked: false, at: now.addingTimeInterval(-7_200))
        var past = obs(conf: 60, balance: 9, unlocked: 9)
        past.height = 1_031
        let reopened = PaymentLinksStatusChecker.applying(past, to: sent, transactions: [], now: now).record
        XCTAssertEqual(reopened.status, .ready)

        // The new reclaim, saved before its broadcast, refused as a double spend.
        let attempt = EnvelopeRuntime.SweepAttempt(txids: ["r2"], amount: 9, height: 1_040, leavesLocked: false)
        let saved = EnvelopeSession.settling(reopened, attempt: attempt, walletName: "Main", now: now)
        func after(_ before: EnvelopeRecord, _ transactions: [MoneroTransaction] = []) -> EnvelopeRecord? {
            EnvelopeSession.afterFailedSweep(EnvelopeSession.settling(before, attempt: attempt, walletName: "Main", now: now), before: before,
                                             error: Failure.alreadyClaimed, transactions: transactions, now: now)
        }
        let lost = try XCTUnwrap(EnvelopeSession.afterFailedSweep(saved, before: reopened, error: Failure.alreadyClaimed, now: now))
        XCTAssertEqual(lost.status, .reclaimed)
        XCTAssertEqual(lost.settleTxid, "r1")
        XCTAssertEqual(lost.settledAmount, 9)
        XCTAssertEqual(PaymentLinkDisplay(record: lost, fundingConfirmations: nil, daemonHeight: nil).label, "Reclaimed")
        // This wallet's history shows the first reclaim: ours.
        XCTAssertEqual(after(reopened, [history("r1", .confirmed)])?.settleTxid, "r1")
        // The history marks it failed: a claim made elsewhere won.
        XCTAssertEqual(after(reopened, [history("r1", .failed)])?.status, .claimed)
        XCTAssertNil(after(reopened, [history("r1", .failed)])?.settleTxid)
        // No reclaim of ours before: Claimed.
        XCTAssertEqual(after(neverReclaimed)?.status, .claimed)

        // The next scan decides: our first reclaim mined, final.
        let mined = PaymentLinksStatusChecker.applying(obs(conf: 60, spends: ["r1"], mined: ["r1"]), to: lost, transactions: [], now: now)
        XCTAssertEqual(mined.record.status, .reclaimed)
        XCTAssertTrue(mined.conclusive)
        // A claim made elsewhere: Claimed.
        XCTAssertEqual(PaymentLinksStatusChecker.applying(obs(conf: 60, spends: ["theirs"], mined: ["theirs"]), to: lost,
                                                          transactions: [], now: now).record.status, .claimed)
    }
}
