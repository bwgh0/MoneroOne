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
        // A confirmed sweep can leave a newer, still-locked funding behind.
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 7, spends: ["ours"]), reclaimTxid: "ours"), .pending)
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 7, unlocked: 7, spends: ["ours"]), reclaimTxid: "ours"), .ready)
        // A claim won the race against our reclaim.
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"]), reclaimTxid: "ours"), .claimed)
    }

    /// Link 10: the wallet's history has the funding, the envelope's scan
    /// did not see it. The link waits; it is never Not funded.
    func testAKnownFundingIsNeverNotFunded() {
        let rules = EnvelopeStatusRules.self
        XCTAssertEqual(rules.status(for: .empty, reclaimTxid: nil, fundingKnown: true), .pending)
        XCTAssertEqual(rules.status(for: .empty, reclaimTxid: nil, fundingKnown: false), .notFunded)
        // What the scan sees still wins once it sees the funding.
        XCTAssertEqual(rules.status(for: obs(conf: 12, balance: 5, unlocked: 5), reclaimTxid: nil, fundingKnown: true), .ready)
        XCTAssertEqual(rules.status(for: obs(conf: 12, spends: ["claim"]), reclaimTxid: nil, fundingKnown: true), .claimed)

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
        XCTAssertEqual(actions(.received, .claimed), [.claim])
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
        XCTAssertEqual(pool, poolExpected)

        let mined = EnvelopeRuntime.observation(
            transactions: [tx("f", .incoming, height: 190), tx("c", .outgoing, height: 199, amount: "0.4", fee: "0.1"), tx("x", .outgoing, height: nil, status: .failed)],
            balance: Decimal(string: "0.5")!, unlocked: Decimal(string: "0.5")!, daemonHeight: 200
        )
        var expected = obs(conf: 10, balance: 500_000_000_000, unlocked: 500_000_000_000, spends: ["c"])
        expected.fundingHeight = 190
        expected.fundingTxids = ["f"]
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
        XCTAssertEqual(PaymentLinkDetailAction.actions(for: saved, display: display), [.claim])
        // A claim does not make an envelope with newer locked funds settled.
        XCTAssertEqual(EnvelopeStatusRules.status(for: obs(conf: 12, balance: 7, unlocked: 0, spends: ["mined-claim"]), reclaimTxid: nil), .pending)
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
}
