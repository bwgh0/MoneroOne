import XCTest
@testable import MoneroOne

/// Payment links in Activity: which transactions belong to a link and how
/// their rows read. Android ports the same rules.
final class PaymentLinkActivityTests: XCTestCase {
    private func record(
        _ role: EnvelopeRecord.Role,
        id: String = "0123456789abcdef",
        status: EnvelopeStatus = .pending,
        fundingTxid: String? = nil,
        settleTxid: String? = nil
    ) -> EnvelopeRecord {
        var record = EnvelopeRecord(id: id, role: role, words: nil, address: "addr", restoreHeight: 150,
                                    amount: 500_000_000_000, expiry: 0, createdAt: Date(), status: status)
        record.fundingTxid = fundingTxid
        record.settleTxid = settleTxid
        return record
    }

    // MARK: - Matching

    func testFundingMatchesTheOutgoingTransactionOnly() {
        let sent = record(.sent, fundingTxid: "f1")
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "f1", isIncoming: false, records: [sent])?.kind, .funding)
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "f1", isIncoming: true, records: [sent]))
    }

    func testReclaimAndClaimMatchIncomingSettleTransactions() {
        let sent = record(.sent, id: "a", status: .reclaimed, fundingTxid: "f1", settleTxid: "s1")
        let received = record(.received, id: "b", status: .claimed, settleTxid: "c1")
        let records = [sent, received]
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "s1", isIncoming: true, records: records)?.kind, .reclaim)
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "c1", isIncoming: true, records: records)?.kind, .claim)
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "c1", isIncoming: true, records: records)?.record.id, "b")
        // A settle txid never labels an outgoing row.
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "s1", isIncoming: false, records: records))
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "c1", isIncoming: false, records: records))
    }

    func testOtherTransactionsDoNotMatch() {
        let records = [record(.sent, fundingTxid: "f1"), record(.received, id: "b", settleTxid: "c1")]
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "other", isIncoming: true, records: records))
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "other", isIncoming: false, records: records))
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "f1", isIncoming: false, records: []))
    }

    func testTitles() {
        XCTAssertEqual(PaymentLinkActivity(kind: .funding, record: record(.sent)).title, "Sent by Link")
        XCTAssertEqual(PaymentLinkActivity(kind: .reclaim, record: record(.sent)).title, "Reclaimed by Link")
        XCTAssertEqual(PaymentLinkActivity(kind: .claim, record: record(.received)).title, "Received by Link")
    }

    // MARK: - Row status and amount

    func testFundingRowShowsTheLinkState() {
        let state = PaymentLinkRowStatus.funding
        XCTAssertEqual(state(.created, false, nil), .waiting)
        XCTAssertEqual(state(.notFunded, false, nil), .waiting)
        XCTAssertEqual(state(.pending, false, 3), .waiting)
        XCTAssertEqual(state(.pending, false, 10), .ready)
        XCTAssertEqual(state(.ready, false, 12), .ready)
        XCTAssertEqual(state(.ready, true, 12), .expired)
        XCTAssertEqual(state(.pending, true, 3), .expired)
        XCTAssertEqual(state(.claimed, true, nil), .claimed)
        XCTAssertEqual(state(.reclaimed, false, nil), .reclaimed)

        XCTAssertEqual(PaymentLinkRowStatus.waiting.text, "Waiting")
        XCTAssertEqual(PaymentLinkRowStatus.ready.text, "Ready")
        XCTAssertEqual(PaymentLinkRowStatus.claimed.text, "Claimed")
        XCTAssertEqual(PaymentLinkRowStatus.reclaimed.text, "Reclaimed")
        XCTAssertEqual(PaymentLinkRowStatus.expired.text, "Expired")
        XCTAssertEqual(PaymentLinkRowStatus.readyToClaim.text, "Ready to claim")
    }

    func testRowStatusColours() {
        XCTAssertEqual(PaymentLinkRowStatus.waiting.dotColor, .brand)
        XCTAssertEqual(PaymentLinkRowStatus.ready.dotColor, .green)
        XCTAssertEqual(PaymentLinkRowStatus.claimed.dotColor, .green)
        XCTAssertEqual(PaymentLinkRowStatus.readyToClaim.dotColor, .green)
        XCTAssertEqual(PaymentLinkRowStatus.reclaimed.dotColor, .gray)
        // Caution: a yellow dot, the text in the label colour.
        XCTAssertEqual(PaymentLinkRowStatus.expired.dotColor, .yellow)
        XCTAssertEqual(PaymentLinkRowStatus.expired.textColor, .primary)
        XCTAssertEqual(PaymentLinkRowStatus.waiting.textColor, .brand)
    }

    func testLinkToClaimIsReadyOrWaiting() {
        XCTAssertEqual(PaymentLinkRowStatus.toClaim(.ready), .readyToClaim)
        XCTAssertEqual(PaymentLinkRowStatus.toClaim(.waiting(minutes: 4)), .waiting)
        XCTAssertEqual(PaymentLinkRowStatus.toClaim(.unchecked), .waiting)
        XCTAssertEqual(PaymentLinkRowStatus.toClaim(.noMoney), .waiting)
    }

    /// Reclaim and claim rows, and a funding transaction that failed, show
    /// the transaction's status.
    @MainActor
    func testOnlyFundingRowsShowTheLinkState() {
        let sent = record(.sent, status: .claimed, fundingTxid: "fund", settleTxid: "back")
        XCTAssertEqual(PaymentLinkActivity(kind: .funding, record: sent).rowStatus(transactionFailed: false, walletManager: nil), .claimed)
        XCTAssertNil(PaymentLinkActivity(kind: .funding, record: sent).rowStatus(transactionFailed: true, walletManager: nil))
        XCTAssertNil(PaymentLinkActivity(kind: .reclaim, record: sent).rowStatus(transactionFailed: false, walletManager: nil))
        let received = record(.received, status: .claimed, settleTxid: "claim")
        XCTAssertNil(PaymentLinkActivity(kind: .claim, record: received).rowStatus(transactionFailed: false, walletManager: nil))
    }

    /// One amount per link: a funding row shows what the recipient gets,
    /// not the funding transaction (amount + claim fee reserve).
    func testFundingRowShowsTheLinkAmount() {
        var sent = record(.sent, fundingTxid: "fund", settleTxid: "back")
        sent.amount = 20_000_000_000
        sent.feeReserve = 31_000_000
        let funding = Decimal(string: "0.020031")!
        XCTAssertEqual(PaymentLinkActivity(kind: .funding, record: sent).rowAmount(transactionAmount: funding), Decimal(string: "0.02")!)
        // What came back or came in stays the transaction's.
        let back = Decimal(string: "0.02001")!
        XCTAssertEqual(PaymentLinkActivity(kind: .reclaim, record: sent).rowAmount(transactionAmount: back), back)
        XCTAssertEqual(PaymentLinkActivity(kind: .claim, record: record(.received)).rowAmount(transactionAmount: back), back)
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(
            PaymentLinkActivity.accessibilityLabel(kind: "Sent by Link", name: "Dinner", isIncoming: false,
                                                   amountSpoken: "0.02 XMR", status: "Waiting", date: "Oct 16"),
            "Sent by Link, Dinner, minus 0.02 XMR, Waiting, Oct 16"
        )
        XCTAssertEqual(
            PaymentLinkActivity.accessibilityLabel(kind: "Received by Link", name: "Link 3", isIncoming: true,
                                                   amountSpoken: "0.25 XMR", status: "Pending", date: "1 min. ago"),
            "Received by Link, Link 3, plus 0.25 XMR, Pending, 1 min. ago"
        )
    }

    // MARK: - Received links at the top of Activity

    func testPendingStateFromTheRecord() {
        let state = PendingPaymentLinks.state
        XCTAssertEqual(state(record(.received, status: .created), 500, Date()), .unchecked)
        XCTAssertEqual(state(record(.received, status: .notFunded), 500, Date()), .noMoney)
        XCTAssertEqual(state(record(.received, status: .ready), 0, Date()), .ready)
    }

    /// The founder's bug: a sent link's funding had 10 confirmations, its
    /// record still said pending (no check had seen the unlock), and the row
    /// said "Ready to claim" while the detail said "Pending 10/10" with
    /// Reclaim off. The row, the detail and Reclaim now read one status.
    func testSentLinkIsReadyAtTheUnlockDepthWhateverTheLastCheck() {
        func display(_ record: EnvelopeRecord, funding: Int?, daemonHeight: UInt64? = nil, now: Date = Date()) -> PaymentLinkDisplay {
            PaymentLinkDisplay(record: record, fundingConfirmations: funding, daemonHeight: daemonHeight, now: now)
        }
        func row(_ display: PaymentLinkDisplay) -> PaymentLinkRowStatus {
            PaymentLinkRowStatus.funding(status: display.status, isExpired: display.isExpired, confirmations: display.confirmations)
        }
        var stale = record(.sent, status: .pending, fundingTxid: "fund")
        stale.confirmations = 2
        stale.lastCheckedAt = Date(timeIntervalSinceNow: -3600)

        let ready = display(stale, funding: 10)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.label, "Ready")
        XCTAssertEqual(row(ready), .ready)
        XCTAssertTrue(ready.canReclaim)

        let young = display(stale, funding: 9)
        XCTAssertEqual(young.status, .pending)
        XCTAssertEqual(young.label, "Pending 9/10")
        XCTAssertEqual(row(young), .waiting)
        XCTAssertFalse(young.canReclaim)

        // Another wallet funded it: the funding height of the last check and
        // the daemon height give the count.
        var elsewhere = stale
        elsewhere.fundingHeight = 1_000
        XCTAssertTrue(display(elsewhere, funding: nil, daemonHeight: 1_010).canReclaim)
        XCTAssertFalse(display(elsewhere, funding: nil, daemonHeight: 1_009).canReclaim)

        // Past its expiry it reads Expired, and Reclaim is on.
        stale.expiry = Int64(Date().timeIntervalSince1970) - 60
        let expired = display(stale, funding: 12)
        XCTAssertEqual(expired.label, "Expired")
        XCTAssertEqual(row(expired), .expired)
        XCTAssertTrue(expired.canReclaim)

        // A check that saw the claim wins over the count.
        let claimed = display(record(.sent, status: .claimed, fundingTxid: "fund"), funding: 30)
        XCTAssertEqual(claimed.status, .claimed)
        XCTAssertFalse(claimed.canReclaim)
        // Never on a received link.
        var received = record(.received, status: .pending)
        received.confirmations = 10
        received.lastCheckedAt = Date()
        XCTAssertFalse(display(received, funding: nil).canReclaim)
    }

    /// A received link's detail says the same as its pinned row.
    @MainActor
    func testReceivedLinkDetailMatchesThePinnedRow() {
        let empty = PaymentLinkDisplay(record: record(.received, status: .notFunded), walletManager: nil)
        XCTAssertEqual(empty.label, PendingPaymentLinks.label(for: .noMoney))

        var unlocked = record(.received, status: .pending)
        unlocked.confirmations = 10
        unlocked.lastCheckedAt = Date()
        let ready = PaymentLinkDisplay(record: unlocked, walletManager: nil)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.label, PendingPaymentLinks.label(for: .ready))

        var young = record(.received, status: .pending)
        young.confirmations = 2
        young.lastCheckedAt = Date()
        XCTAssertEqual(PaymentLinkDisplay(record: young, walletManager: nil).label, "Pending 2/10")
    }

    func testPendingCountsDownFromTheFundingHeight() {
        var pending = record(.received, status: .pending)
        pending.fundingHeight = 400
        // 4 confirmations: 6 blocks of 2 minutes left.
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 404), .waiting(minutes: 12))
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 409), .waiting(minutes: 2))
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 410), .ready)
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 450), .ready)
    }

    func testPendingWithoutAHeightCountsDownFromTheLastCheck() {
        var pending = record(.received, status: .pending)
        pending.confirmations = 0
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        pending.lastCheckedAt = checked
        // In the mempool at the check: 20 minutes, less the time since.
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 0, now: checked), .waiting(minutes: 20))
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 0, now: checked + 5 * 60), .waiting(minutes: 15))
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 0, now: checked + 21 * 60), .ready)
        // A daemon height below the funding height (a node behind) is not used.
        pending.fundingHeight = 500
        XCTAssertEqual(PendingPaymentLinks.state(of: pending, daemonHeight: 450, now: checked + 5 * 60), .waiting(minutes: 15))
    }

    @MainActor
    func testOnlyUnsettledReceivedLinksWithASecretArePinned() throws {
        let service = "one.monero.MoneroOne.paymentlinks.tests.\(UUID().uuidString)"
        let store = EnvelopeStore(service: service)
        defer { store.removeAll() }
        func received(_ id: String, _ status: EnvelopeStatus, secret: Bool = true) -> EnvelopeRecord {
            var r = record(.received, id: id, status: status)
            if secret { r.secret = "000102030405060708090a0b0c0d0e0f" }
            return r
        }
        try store.save(received("a", .pending))
        try store.save(received("b", .created))
        try store.save(received("c", .claimed))
        try store.save(received("d", .reclaimed))
        try store.save(received("e", .ready, secret: false))
        try store.save(record(.sent, id: "f", status: .pending))
        XCTAssertEqual(Set(PendingPaymentLinks.records(in: store).map(\.id)), ["a", "b"])
    }

    // MARK: - Open links (balance card lines, Links filter)

    private func open(
        _ role: EnvelopeRecord.Role,
        _ status: EnvelopeStatus,
        id: String = UUID().uuidString,
        amount: UInt64 = 50_000_000_000,
        walletId: String? = "w1",
        expiry: Int64 = 0,
        secret: Bool = true,
        fundingTxid: String? = "tx"
    ) -> EnvelopeRecord {
        var r = EnvelopeRecord(id: id, role: role, words: nil, address: "addr", restoreHeight: 150,
                               amount: amount, expiry: expiry, createdAt: Date(), status: status)
        r.walletId = role == .sent ? walletId : nil
        r.fundingTxid = role == .sent ? fundingTxid : nil
        if secret { r.secret = "000102030405060708090a0b0c0d0e0f" }
        return r
    }

    func testOpenSentLinksArePendingOrReadyFromThisWallet() {
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(open(.sent, .pending), activeWalletId: "w1"))
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(open(.sent, .ready), activeWalletId: "w1"))
        // Expired is a label over pending and ready: still open.
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(open(.sent, .ready, expiry: 1), activeWalletId: "w1"))
        // Settled, or never funded: nothing in the link.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .claimed), activeWalletId: "w1"))
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .reclaimed), activeWalletId: "w1"))
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .notFunded, fundingTxid: nil), activeWalletId: "w1"))
        // A funding whose result is not known yet is not counted.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .pending, fundingTxid: nil), activeWalletId: "w1"))
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .ready, fundingTxid: nil), activeWalletId: "w1"))
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .created, fundingTxid: nil), activeWalletId: "w1"))
        // Another wallet's link is that wallet's money; an old record without
        // a wallet id counts everywhere.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.sent, .pending, walletId: "w2"), activeWalletId: "w1"))
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(open(.sent, .pending, walletId: nil), activeWalletId: "w1"))
        // A received link is never one of ours.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(open(.received, .ready), activeWalletId: "w1"))
    }

    func testLinksToClaimAreUnsettledReceivedLinksWithTheirSecret() {
        XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(open(.received, .pending)))
        XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(open(.received, .ready)))
        XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(open(.received, .created)))
        XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(open(.received, .claimed)))
        XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(open(.received, .reclaimed)))
        XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(open(.received, .ready, secret: false)))
        XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(open(.sent, .ready)))
    }

    func testSummaryAddsTheOpenLinks() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            open(.sent, .pending, amount: 50_000_000_000),
            open(.sent, .ready, amount: 250_000_000_000),
            open(.sent, .ready, amount: 100_000_000_000, expiry: 1_000_000),
            open(.sent, .claimed, amount: 900_000_000_000),
            open(.sent, .pending, amount: 900_000_000_000, walletId: "w2"),
            open(.received, .ready, amount: 30_000_000_000),
            open(.received, .claimed, amount: 900_000_000_000),
        ]
        let summary = OpenPaymentLinks.summary(of: records, activeWalletId: "w1", now: now)
        XCTAssertEqual(summary.sentCount, 3)
        XCTAssertEqual(summary.sentAmount, 400_000_000_000)
        XCTAssertEqual(summary.expiredCount, 1)
        XCTAssertEqual(summary.toClaimCount, 1)
        XCTAssertEqual(summary.toClaimAmount, 30_000_000_000)
        XCTAssertFalse(summary.isEmpty)

        XCTAssertTrue(OpenPaymentLinks.summary(of: [open(.sent, .claimed)], activeWalletId: "w1").isEmpty)
        XCTAssertTrue(OpenPaymentLinks.summary(of: [], activeWalletId: "w1").isEmpty)
    }

    func testSummaryClaimAmountIsUnknownWhileALinkHasNoAmount() {
        let records = [open(.received, .ready, amount: 30_000_000_000), open(.received, .created, amount: 0)]
        let summary = OpenPaymentLinks.summary(of: records, activeWalletId: nil)
        XCTAssertEqual(summary.toClaimCount, 2)
        XCTAssertNil(summary.toClaimAmount)
    }

    // MARK: - Net claim amount

    func testNetAmountIsTheBalanceLessTheSweepFee() {
        XCTAssertEqual(EnvelopeRecord.net(balance: 27_200_000_000, fee: 7_100_000_000), 20_100_000_000)
        XCTAssertNil(EnvelopeRecord.net(balance: 7_100_000_000, fee: 7_100_000_000))
        XCTAssertNil(EnvelopeRecord.net(balance: 0, fee: 1))
    }

    func testACheckStoresTheNetAmountOfAReceivedLinkOnly() {
        var received = open(.received, .pending, amount: 0)
        received.noteBalance(27_200_000_000, sweepFee: 7_100_000_000)
        XCTAssertEqual(received.lastBalance, 27_200_000_000)
        XCTAssertEqual(received.netAmount, 20_100_000_000)
        XCTAssertEqual(received.claimAmount, 20_100_000_000)
        // No estimate this time: the net amount holds while the balance does.
        received.noteBalance(27_200_000_000, sweepFee: nil)
        XCTAssertEqual(received.netAmount, 20_100_000_000)
        received.noteBalance(30_000_000_000, sweepFee: nil)
        XCTAssertNil(received.netAmount)
        XCTAssertEqual(received.claimAmount, 30_000_000_000)

        var sent = open(.sent, .ready, amount: 20_000_000_000)
        sent.noteBalance(27_200_000_000, sweepFee: 7_100_000_000)
        XCTAssertEqual(sent.lastBalance, 27_200_000_000)
        XCTAssertNil(sent.netAmount)
    }

    func testClaimAmountPrefersTheNetThenTheV1AmountThenTheBalance() {
        var v2 = open(.received, .ready, amount: 0)
        XCTAssertNil(v2.claimAmount)
        v2.lastBalance = 27_200_000_000
        XCTAssertEqual(v2.claimAmount, 27_200_000_000)
        v2.netAmount = 20_100_000_000
        XCTAssertEqual(v2.claimAmount, 20_100_000_000)

        var v1 = open(.received, .ready, amount: 20_000_000_000)
        v1.lastBalance = 27_200_000_000
        XCTAssertEqual(v1.claimAmount, 20_000_000_000)
        v1.netAmount = 20_100_000_000
        XCTAssertEqual(v1.claimAmount, 20_100_000_000)
    }

    func testOnlyV2LinksCheckedWithoutANetAmountNeedTheActiveWalletsEstimate() {
        var old = open(.received, .ready, amount: 0)
        old.lastBalance = 27_200_000_000
        XCTAssertTrue(old.needsNetAmount)

        var netted = old
        netted.netAmount = 20_100_000_000
        XCTAssertFalse(netted.needsNetAmount)
        var claimed = old
        claimed.status = .claimed
        XCTAssertFalse(claimed.needsNetAmount)
        var v1 = open(.received, .ready, amount: 20_000_000_000)
        v1.lastBalance = 27_200_000_000
        XCTAssertFalse(v1.needsNetAmount)
        var sent = open(.sent, .ready, amount: 0)
        sent.lastBalance = 27_200_000_000
        XCTAssertFalse(sent.needsNetAmount)
        XCTAssertFalse(open(.received, .created, amount: 0).needsNetAmount)
    }

    func testSummaryCountsWhatTheClaimsDeliverAndWhatWasSent() {
        var checked = open(.received, .ready, amount: 0)
        checked.noteBalance(27_200_000_000, sweepFee: 7_100_000_000)
        let records = [checked, open(.received, .pending, amount: 30_000_000_000), open(.sent, .pending, amount: 20_000_000_000)]
        let summary = OpenPaymentLinks.summary(of: records, activeWalletId: "w1")
        XCTAssertEqual(summary.toClaimAmount, 50_100_000_000)
        XCTAssertEqual(summary.sentAmount, 20_000_000_000)
    }

    // MARK: - Home line

    /// The line opens the Links filter for any count, one link too; it
    /// counts only this wallet's open links.
    func testHomeLineCountsThisWalletsOpenLinks() {
        let one = OpenPaymentLinks.summary(of: [open(.sent, .pending, id: "a"), open(.received, .ready, id: "r")], activeWalletId: "w1")
        XCTAssertEqual(one.sentCount, 1)
        XCTAssertEqual(one.toClaimCount, 1)

        let two = OpenPaymentLinks.summary(of: [open(.sent, .pending, id: "a"), open(.sent, .ready, id: "b")], activeWalletId: "w1")
        XCTAssertEqual(two.sentCount, 2)

        // A link from another wallet is not this wallet's open link.
        let other = OpenPaymentLinks.summary(of: [open(.sent, .pending, id: "a", walletId: "w2"), open(.sent, .pending, id: "b")], activeWalletId: "w1")
        XCTAssertEqual(other.sentCount, 1)
        XCTAssertTrue(OpenPaymentLinks.Summary().isEmpty)
    }

    // MARK: - Links filter

    private func tx(_ id: String, _ type: MoneroTransaction.TransactionType, at seconds: TimeInterval,
                    status: MoneroTransaction.TransactionStatus = .confirmed) -> MoneroTransaction {
        MoneroTransaction(id: id, type: type, amount: 1, fee: 0, address: "", timestamp: Date(timeIntervalSince1970: seconds),
                          confirmations: 20, status: status, memo: nil, blockHeight: 1)
    }

    /// Open: links that still hold money. History: everything else. Each
    /// row once, newest first; the card counts each link once.
    func testLinksFilterSplitsOpenAndHistoryWithEachRowOnce() {
        var waiting = open(.sent, .pending, id: "waiting", fundingTxid: "f-waiting")
        waiting.createdAt = Date(timeIntervalSince1970: 900)
        let expired = open(.sent, .ready, id: "expired", expiry: 1, fundingTxid: "f-expired")
        let claimed = open(.sent, .claimed, id: "claimed", fundingTxid: "f-claimed")
        var reclaimed = open(.sent, .reclaimed, id: "reclaimed", fundingTxid: "f-reclaimed")
        reclaimed.settleTxid = "s-reclaimed"
        var received = open(.received, .claimed, id: "received", secret: false)
        received.settleTxid = "s-received"
        let failed = open(.sent, .pending, id: "failed", fundingTxid: "f-failed")
        var toClaim = open(.received, .ready, id: "toClaim")
        toClaim.createdAt = Date(timeIntervalSince1970: 650)
        let records = [waiting, expired, claimed, reclaimed, received, failed, toClaim]

        let transactions = [
            tx("f-waiting", .outgoing, at: 900),
            tx("s-received", .incoming, at: 800),
            tx("f-expired", .outgoing, at: 700),
            tx("s-reclaimed", .incoming, at: 600),
            tx("f-failed", .outgoing, at: 550, status: .failed),
            tx("f-reclaimed", .outgoing, at: 500),
            tx("f-claimed", .outgoing, at: 400),
        ]
        let linksToClaim = TransactionListLogic.linksToClaim(records, type: .links, receivingIndex: nil, search: "", asOf: nil)
        let items = TransactionListLogic.items(transactions: transactions, linksToClaim: linksToClaim)
        XCTAssertEqual(items.map(\.id), [
            "tx.f-waiting.out", "tx.s-received.in", "tx.f-expired.out", "link.toClaim",
            "tx.s-reclaimed.in", "tx.f-failed.out", "tx.f-reclaimed.out", "tx.f-claimed.out",
        ])

        let sections = TransactionListLogic.linkSections(items, records: records)
        XCTAssertEqual(sections.open.map(\.id), ["tx.f-waiting.out", "tx.f-expired.out", "link.toClaim"])
        XCTAssertEqual(sections.history.map(\.id), [
            "tx.s-received.in", "tx.s-reclaimed.in", "tx.f-failed.out", "tx.f-reclaimed.out", "tx.f-claimed.out",
        ])
        // No row twice, none left out.
        let all = sections.open.map(\.id) + sections.history.map(\.id)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(Set(all), Set(items.map(\.id)))

        // 7 links (the reclaimed one has two rows), 3 open.
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle(items, openCount: sections.open.count, records: records), "7 links · 3 open")
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle(sections.history, openCount: 0, records: records), "4 links")
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle([items[0]], openCount: 1, records: records), "1 link · 1 open")
    }

    /// A link whose funding never went out (no funding transaction, none to
    /// its address) is in no filter, no count and no home line. Its record
    /// and secret stay.
    func testAnUnfundedLinkIsHidden() {
        let unfunded = open(.sent, .notFunded, id: "unfunded", fundingTxid: nil)
        let created = open(.sent, .created, id: "created", fundingTxid: nil)
        let records = [unfunded, created]
        let transactions = [tx("other", .outgoing, at: 900), tx("in", .incoming, at: 800)]
        for type in [TransactionListView.FilterType.all, .links] {
            let rows = TransactionListLogic.filter(transactions, type: type, receivingIndex: nil, search: "", linkRecords: records)
            XCTAssertTrue(rows.allSatisfy { PaymentLinkActivity.match(transactionId: $0.id, isIncoming: $0.type == .incoming, records: records) == nil })
            XCTAssertTrue(TransactionListLogic.linksToClaim(records, type: type, receivingIndex: nil, search: "", asOf: nil).isEmpty)
        }
        XCTAssertTrue(TransactionListLogic.filter(transactions, type: .links, receivingIndex: nil, search: "", linkRecords: records).isEmpty)
        let items = TransactionListLogic.items(transactions: transactions, linksToClaim: [])
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle([], openCount: 0, records: records), "0 links")
        XCTAssertTrue(TransactionListLogic.linkSections(items, records: records).open.isEmpty)
        XCTAssertTrue(OpenPaymentLinks.summary(of: records, activeWalletId: "w1").isEmpty)
        XCTAssertNotNil(unfunded.link)
        // The history has nothing for it: nothing changes.
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: records, activeWalletId: "w1", transactions: transactions).isEmpty)
    }

    /// The same link once its funding shows up in the wallet's history: a
    /// normal waiting link again, in the Links filter, its card and the
    /// home line.
    func testAnUnfundedLinkReappearsWhenItsFundingShowsUp() throws {
        let unfunded = open(.sent, .notFunded, id: "unfunded", fundingTxid: nil)
        let funding = MoneroTransaction(
            id: "f-late", type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(timeIntervalSince1970: 900),
            confirmations: 3, status: .confirmed, memo: nil, blockHeight: 1_934,
            destinations: [MoneroTransactionDestination(address: "addr", amount: 1)]
        )
        let updates = PaymentLinksStatusChecker.fundingUpdates(sent: [unfunded], activeWalletId: "w1", transactions: [funding])
        let found = try XCTUnwrap(updates.first)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(found.fundingTxid, "f-late")
        XCTAssertEqual(found.status, .pending)
        XCTAssertEqual(found.fundingHeight, 1_934)
        XCTAssertNotNil(found.link)

        XCTAssertTrue(OpenPaymentLinks.isOpenSent(found, activeWalletId: "w1"))
        XCTAssertEqual(OpenPaymentLinks.summary(of: [found], activeWalletId: "w1").sentCount, 1)
        let rows = TransactionListLogic.filter([funding], type: .links, receivingIndex: nil, search: "", linkRecords: [found])
        XCTAssertEqual(rows.map(\.id), ["f-late"])
        let items = TransactionListLogic.items(transactions: rows, linksToClaim: [])
        XCTAssertEqual(TransactionListLogic.linkSections(items, records: [found]).open.count, 1)
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle(items, openCount: 1, records: [found]), "1 link · 1 open")

        // Another wallet's history never claims it.
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: [unfunded], activeWalletId: "w2", transactions: [funding]).isEmpty)
        // A failed send moved nothing.
        let failed = MoneroTransaction(
            id: "f-failed", type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(), confirmations: 0,
            status: .failed, memo: nil, blockHeight: nil, destinations: [MoneroTransactionDestination(address: "addr", amount: 1)]
        )
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: [unfunded], activeWalletId: "w1", transactions: [failed]).isEmpty)
    }

    /// Link 10: a funding transaction in the history and a check that wrote
    /// Not funded. It reads Waiting or Ready, stays open, and its funding
    /// block is saved for the next scan.
    func testAFundedLinkNeverReadsNotFunded() throws {
        var link10 = open(.sent, .notFunded, id: "link10", fundingTxid: "f10")
        link10.confirmations = 0
        let pending = PaymentLinkDisplay(record: link10, fundingConfirmations: 3, daemonHeight: nil)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.label, "Pending 3/10")
        let ready = PaymentLinkDisplay(record: link10, fundingConfirmations: 81, daemonHeight: nil)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.label, "Ready")
        XCTAssertTrue(ready.canReclaim)
        // Funded from another wallet: no count here, still waiting.
        XCTAssertEqual(PaymentLinkDisplay(record: link10, fundingConfirmations: nil, daemonHeight: nil).label, "Pending 0/10")
        XCTAssertEqual(PaymentLinkRowStatus.funding(status: pending.status, isExpired: false, confirmations: 3), .waiting)

        XCTAssertTrue(OpenPaymentLinks.isOpenSent(link10, activeWalletId: "w1"))
        XCTAssertEqual(OpenPaymentLinks.summary(of: [link10], activeWalletId: "w1").sentCount, 1)

        let funding = MoneroTransaction(
            id: "f10", type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(), confirmations: 81,
            status: .confirmed, memo: nil, blockHeight: 3_785_658
        )
        let fixed = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(sent: [link10], activeWalletId: "w1", transactions: [funding]).first)
        XCTAssertEqual(fixed.status, .pending)
        XCTAssertEqual(fixed.fundingHeight, 3_785_658)
        XCTAssertEqual(PaymentLinksStatusChecker.fundingHeight(of: link10, in: [funding]), 3_785_658)
        XCTAssertNil(PaymentLinksStatusChecker.fundingHeight(of: link10, in: []))
        // Up to date: nothing to save.
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: [fixed], activeWalletId: "w1", transactions: [funding]).isEmpty)
    }

    func testSentLineText() {
        XCTAssertEqual(OpenPaymentLinks.sentLineText(amount: 50_000_000_000, count: 1, expired: 0), "0.0500 XMR in 1 open link")
        XCTAssertEqual(OpenPaymentLinks.sentLineText(amount: 150_000_000_000, count: 2, expired: 0), "0.1500 XMR in 2 open links")
        XCTAssertEqual(OpenPaymentLinks.sentLineText(amount: 400_000_000_000, count: 3, expired: 1), "0.4000 XMR in 3 open links · 1 expired")
        XCTAssertEqual(OpenPaymentLinks.sentLineText(amount: 400_000_000_000, count: 3, expired: 2), "0.4000 XMR in 3 open links · 2 expired")
    }

    func testSentLineAccessibilityLabel() {
        XCTAssertEqual(OpenPaymentLinks.sentAccessibilityLabel(amount: 150_000_000_000, count: 2, expired: 1), "0.1500 XMR in 2 open links, 1 expired")
        XCTAssertEqual(OpenPaymentLinks.sentAccessibilityLabel(amount: 50_000_000_000, count: 1, expired: 0), "0.0500 XMR in 1 open link")
    }

    func testClaimLineText() {
        // An estimate, as on its Activity row and the claim sheet.
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: 30_000_000_000, count: 1), "~0.0300 XMR to claim")
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: nil, count: 1), "1 link to claim")
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: nil, count: 2), "2 links to claim")
        XCTAssertEqual(OpenPaymentLinks.claimAccessibilityLabel(amount: 30_000_000_000, count: 1), "about 0.0300 XMR to claim")
        XCTAssertEqual(OpenPaymentLinks.claimAccessibilityLabel(amount: nil, count: 2), "2 links to claim")
    }

    /// In Fiat Mode the lines lead with fiat at today's price, as the
    /// Activity rows do.
    func testLinesFollowFiatMode() {
        XCTAssertEqual(OpenPaymentLinks.sentLineText(amount: 20_000_000_000, fiat: "$11.12", count: 1, expired: 0), "$11.12 in 1 open link")
        XCTAssertEqual(OpenPaymentLinks.sentAccessibilityLabel(amount: 20_000_000_000, fiat: "$11.12", count: 2, expired: 1), "$11.12 in 2 open links, 1 expired")
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: 49_000_000_000, fiat: "$27.34", count: 1), "~$27.34 to claim")
        XCTAssertEqual(OpenPaymentLinks.claimAccessibilityLabel(amount: 49_000_000_000, fiat: "$27.34", count: 1), "about $27.34 to claim")
    }

    /// Activity's Links filter shows each link once: a link sent to us
    /// that waits to be claimed gets a row of its own, newest first; our
    /// open links do not, their "Sent by Link" rows stand for them.
    func testLinksFilterListsOnlyTheLinksToClaim() {
        var older = open(.received, .pending, id: "older")
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        var newer = open(.received, .ready, id: "newer")
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        let records = [
            older, newer,
            open(.received, .claimed, id: "claimed"),
            open(.received, .ready, id: "noSecret", secret: false),
            open(.sent, .pending, id: "sentOpen"),
            open(.sent, .ready, id: "sentExpired", expiry: 1),
        ]
        func rows(_ type: TransactionListView.FilterType = .links, receivingIndex: Int? = nil, search: String = "", asOf: Date? = nil) -> [String] {
            TransactionListLogic.linksToClaim(records, type: type, receivingIndex: receivingIndex, search: search, asOf: asOf).map(\.id)
        }
        XCTAssertEqual(rows(), ["newer", "older"])
        // All shows them too, among the transactions; the other filters
        // list transactions only.
        XCTAssertEqual(rows(.all), ["newer", "older"])
        XCTAssertEqual(rows(.incoming), [])
        XCTAssertEqual(rows(.pending), [])
        XCTAssertEqual(rows(search: "abc"), [])
        XCTAssertEqual(rows(receivingIndex: 1), [])
        XCTAssertEqual(rows(asOf: Date()), [])
    }

    func testLinkToClaimAmountIsAnEstimate() {
        let amount = TransactionAmountText.incomingEstimate(xmr: Decimal(string: "0.0154024")!, fiatNow: "$2.47", fiatFirst: false)
        XCTAssertEqual(amount.primary, "+~0.0154024")
        XCTAssertEqual(amount.secondary, "~$2.47")
        XCTAssertFalse(amount.isFiatFirst)
        XCTAssertEqual(amount.spoken, "about 0.0154024 XMR, worth about $2.47")
    }

    func testLinkToClaimAmountFollowsFiatMode() {
        let amount = TransactionAmountText.incomingEstimate(xmr: Decimal(string: "0.0154024")!, fiatNow: "$2.47", fiatFirst: true)
        XCTAssertEqual(amount.primary, "+~$2.47")
        XCTAssertEqual(amount.secondary, "~0.0154 XMR")
        XCTAssertTrue(amount.isFiatFirst)
        XCTAssertEqual(amount.spoken, "about $2.47, about 0.0154 XMR")

        let noPrice = TransactionAmountText.incomingEstimate(xmr: Decimal(string: "0.0154024")!, fiatNow: nil, fiatFirst: true)
        XCTAssertEqual(noPrice.primary, "+~0.0154024")
        XCTAssertNil(noPrice.secondary)
        XCTAssertFalse(noPrice.isFiatFirst)
    }

    @MainActor
    func testLinkToClaimRowSpeaksAmountAndStatus() {
        XCTAssertEqual(
            PaymentLinkToClaimRow.accessibilityLabel(name: "Link 7", amountSpoken: "about 0.0154024 XMR, worth about $2.47",
                                                     status: "Ready to claim", date: "Oct 16, 2026 at 8:12 PM"),
            "Payment link, Link 7, plus about 0.0154024 XMR, worth about $2.47, Ready to claim, Oct 16, 2026 at 8:12 PM"
        )
        XCTAssertEqual(
            PaymentLinkToClaimRow.accessibilityLabel(name: "Rent", amountSpoken: nil, status: PaymentLinkRowStatus.toClaim(.unchecked).text, date: "Oct 16"),
            "Payment link, Rent, Waiting, Oct 16"
        )
    }

    /// A look stops the active wallet: the dashboard looks when a look is
    /// due (it appeared, the app came back, the wallet changed), else at
    /// most every 10 minutes. Never per block.
    @MainActor
    func testDashboardLooksWhenDueElseEveryTenMinutes() {
        let now = Date()
        typealias Checks = OpenPaymentLinksChecks
        XCTAssertTrue(Checks.isLookDue(isDue: true, lastLook: now, now: now))
        XCTAssertTrue(Checks.isLookDue(isDue: false, lastLook: nil, now: now))
        XCTAssertFalse(Checks.isLookDue(isDue: false, lastLook: now.addingTimeInterval(-2 * 60), now: now))
        XCTAssertFalse(Checks.isLookDue(isDue: false, lastLook: now.addingTimeInterval(-9 * 60), now: now))
        XCTAssertTrue(Checks.isLookDue(isDue: false, lastLook: now.addingTimeInterval(-10 * 60), now: now))
    }

    // MARK: - Received links whose money never came

    /// A received link stays open for its days to claim, then goes to
    /// History as Expired and leaves the home line. Android 1c8809b has the
    /// same rule.
    private func received(_ status: EnvelopeStatus, days: Double, expiry: Int64 = 0, id: String = "r") -> EnvelopeRecord {
        var r = open(.received, status, id: id, expiry: expiry)
        r.createdAt = now.addingTimeInterval(-days * 24 * 60 * 60)
        return r
    }

    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testAReceivedLinkWithNoMoneyExpiresAfter30Days() {
        for status in [EnvelopeStatus.created, .notFunded] {
            XCTAssertFalse(received(status, days: 29).isReceivedExpired(now: now))
            XCTAssertTrue(received(status, days: 31).isReceivedExpired(now: now))
            XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(received(status, days: 29), now: now))
            XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(received(status, days: 31), now: now))
            // Still a link to claim: it keeps its secret.
            XCTAssertTrue(OpenPaymentLinks.isToClaim(received(status, days: 31)))
        }
        // Money in it: open whatever its age.
        for status in [EnvelopeStatus.pending, .ready] {
            XCTAssertFalse(received(status, days: 31).isReceivedExpired(now: now))
            XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(received(status, days: 31), now: now))
        }
        // Settled links and our own links never read this.
        XCTAssertFalse(received(.claimed, days: 31).isReceivedExpired(now: now))
        XCTAssertFalse(received(.reclaimed, days: 31).isReceivedExpired(now: now))
        var sent = open(.sent, .notFunded, fundingTxid: nil)
        sent.createdAt = now.addingTimeInterval(-31 * 24 * 60 * 60)
        XCTAssertFalse(sent.isReceivedExpired(now: now))
    }

    /// A v1 link carries its own expiry; a v2 link (expiry 0) counts 30
    /// days from when this device got it.
    func testAReceivedLinkUsesItsOwnExpiryWhenItHasOne() {
        let rules = EnvelopeStatusRules.self
        let got = now.addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertEqual(rules.claimDeadline(expiry: 0, receivedAt: got), got.addingTimeInterval(EnvelopeLink.defaultLifetime))
        XCTAssertEqual(rules.claimDeadline(expiry: 1_791_000_000, receivedAt: got), Date(timeIntervalSince1970: 1_791_000_000))
        // Two days old, but its own expiry passed.
        XCTAssertTrue(received(.notFunded, days: 2, expiry: 1_791_000_000).isReceivedExpired(now: now))
        XCTAssertFalse(received(.notFunded, days: 31, expiry: 1_793_000_000).isReceivedExpired(now: now))
    }

    @MainActor
    func testAnExpiredReceivedLinkMovesToHistoryAndLeavesTheHomeLine() {
        let fresh = received(.notFunded, days: 29, id: "fresh")
        let old = received(.notFunded, days: 31, id: "old")
        let records = [fresh, old]

        // Links lists both; All only the one still waiting.
        let links = TransactionListLogic.linksToClaim(records, type: .links, receivingIndex: nil, search: "", asOf: nil, now: now)
        XCTAssertEqual(links.map(\.id), ["fresh", "old"])
        let all = TransactionListLogic.linksToClaim(records, type: .all, receivingIndex: nil, search: "", asOf: nil, now: now)
        XCTAssertEqual(all.map(\.id), ["fresh"])

        let items = TransactionListLogic.items(transactions: [], linksToClaim: links)
        let sections = TransactionListLogic.linkSections(items, records: records, now: now)
        XCTAssertEqual(sections.open.map(\.id), ["link.fresh"])
        XCTAssertEqual(sections.history.map(\.id), ["link.old"])
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle(items, openCount: sections.open.count, records: records), "2 links · 1 open")

        // The balance card's Claim line counts the fresh one only.
        XCTAssertEqual(OpenPaymentLinks.summary(of: records, activeWalletId: "w1", now: now).toClaimCount, 1)
        XCTAssertTrue(OpenPaymentLinks.summary(of: [old], activeWalletId: "w1", now: now).isEmpty)

        // Its row and its detail read Expired.
        XCTAssertEqual(PendingPaymentLinks.state(of: old, daemonHeight: 2000, now: now), .expired)
        XCTAssertEqual(PendingPaymentLinks.label(for: .expired), "Expired")
        XCTAssertEqual(PaymentLinkRowStatus.toClaim(.expired), .expired)
        XCTAssertEqual(PendingPaymentLinks.state(of: fresh, daemonHeight: 2000, now: now), .noMoney)
        let display = PaymentLinkDisplay(record: old, fundingConfirmations: nil, daemonHeight: 2000, now: now)
        XCTAssertTrue(display.isExpired)
        XCTAssertEqual(display.label, "Expired")
        XCTAssertFalse(PaymentLinkDisplay(record: fresh, fundingConfirmations: nil, daemonHeight: 2000, now: now).isExpired)
    }

    /// Money that shows up after the 30 days brings the link back to Open.
    @MainActor
    func testAnExpiredReceivedLinkComesBackWhenMoneyShowsUp() {
        var late = received(.notFunded, days: 40, id: "late")
        XCTAssertFalse(OpenPaymentLinks.isWaitingToClaim(late, now: now))
        late.status = .pending
        late.fundingHeight = 1990
        XCTAssertTrue(OpenPaymentLinks.isWaitingToClaim(late, now: now))
        let items = TransactionListLogic.items(transactions: [], linksToClaim: [late])
        XCTAssertEqual(TransactionListLogic.linkSections(items, records: [late], now: now).open.map(\.id), ["link.late"])
        XCTAssertEqual(OpenPaymentLinks.summary(of: [late], activeWalletId: "w1", now: now).toClaimCount, 1)
        XCTAssertEqual(PendingPaymentLinks.state(of: late, daemonHeight: 1995, now: now), .waiting(minutes: 10))
        XCTAssertFalse(PaymentLinkDisplay(record: late, fundingConfirmations: nil, daemonHeight: 1995, now: now).isExpired)
    }

    // MARK: - Orphaned links

    /// A link funded from a wallet that left this device (removed, or
    /// restored from its seed under a new id) belongs to the active wallet:
    /// it counts, gets looked at, adopts its funding and shows in Open with
    /// a row of its own when the history has no funding row for it.
    func testALinkWhoseWalletLeftBelongsToTheActiveWallet() throws {
        let wallets: Set<String> = ["w1", "w2"]
        let orphan = open(.sent, .pending, id: "orphan", walletId: "gone", fundingTxid: "f-gone")
        let other = open(.sent, .pending, id: "other", walletId: "w2", fundingTxid: "f-other")
        XCTAssertTrue(OpenPaymentLinks.belongsToActiveWallet(orphan, activeWalletId: "w1", walletIds: wallets))
        XCTAssertTrue(OpenPaymentLinks.isOpenSent(orphan, activeWalletId: "w1", walletIds: wallets))
        // Another wallet still on this device keeps its own links.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(other, activeWalletId: "w1", walletIds: wallets))
        // The wallets not known (nil or empty): only the funding wallet counts.
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(orphan, activeWalletId: "w1"))
        XCTAssertFalse(OpenPaymentLinks.isOpenSent(orphan, activeWalletId: "w1", walletIds: []))
        XCTAssertFalse(OpenPaymentLinks.belongsToActiveWallet(orphan, activeWalletId: "w1", walletIds: []))
        let summary = OpenPaymentLinks.summary(of: [orphan, other], activeWalletId: "w1", walletIds: wallets)
        XCTAssertEqual(summary.sentCount, 1)
        XCTAssertEqual(summary.sentAmount, orphan.amount)
        XCTAssertTrue(OpenPaymentLinks.needsLook(orphan, activeWalletId: "w1", walletIds: wallets, transactions: [], now: Date()))
        XCTAssertFalse(OpenPaymentLinks.needsLook(other, activeWalletId: "w1", walletIds: wallets, transactions: [], now: Date()))

        // Its funding in the active wallet's history (sent to its address) is adopted.
        let hidden = open(.sent, .notFunded, id: "hidden", walletId: "gone", fundingTxid: nil)
        let funding = MoneroTransaction(
            id: "f-hidden", type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(timeIntervalSince1970: 900),
            confirmations: 3, status: .confirmed, memo: nil, blockHeight: 1_934,
            destinations: [MoneroTransactionDestination(address: "addr", amount: 1)]
        )
        XCTAssertEqual(PaymentLinksStatusChecker.fundingUpdates(sent: [hidden], activeWalletId: "w1", walletIds: wallets,
                                                               transactions: [funding]).first?.fundingTxid, "f-hidden")
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: [hidden], activeWalletId: "w1", transactions: [funding]).isEmpty)

        // The Links filter: a row of its own in Open, counted once.
        let history = [tx("in", .incoming, at: 800)]
        func rows(_ type: TransactionListView.FilterType = .links, search: String = "", asOf: Date? = nil) -> [EnvelopeRecord] {
            TransactionListLogic.openSentWithoutRow([orphan, other], transactions: history, type: type, receivingIndex: nil,
                                                    search: search, asOf: asOf, activeWalletId: "w1", walletIds: wallets)
        }
        XCTAssertEqual(rows().map(\.id), ["orphan"])
        XCTAssertTrue(rows(.all).isEmpty)
        XCTAssertTrue(rows(search: "x").isEmpty)
        XCTAssertTrue(rows(asOf: Date()).isEmpty)
        // A funding row in the history already shows it.
        XCTAssertTrue(TransactionListLogic.openSentWithoutRow([orphan], transactions: [tx("f-gone", .outgoing, at: 900)], type: .links,
                                                              receivingIndex: nil, search: "", asOf: nil, activeWalletId: "w1",
                                                              walletIds: wallets).isEmpty)
        let items = TransactionListLogic.items(transactions: [], linksToClaim: [], openSent: rows())
        let sections = TransactionListLogic.linkSections(items, records: [orphan, other])
        XCTAssertEqual(sections.open.map(\.id), items.map(\.id))
        XCTAssertTrue(sections.history.isEmpty)
        XCTAssertEqual(TransactionListLogic.linksSummaryTitle(items, openCount: 1, records: [orphan, other]), "1 link · 1 open")
    }

    /// A funding wallet2 split into two transactions: both are the link's.
    /// Activity labels each one, the Links filter shows the link once, the
    /// funding is failed only when both failed, and adoption prefers a live one.
    func testEveryTransactionOfASplitFundingIsTheLinks() throws {
        var split = open(.sent, .pending, id: "split", fundingTxid: "f1")
        split.attemptTxids = ["f1", "f2"]
        split.fundingHeight = 2_000
        XCTAssertEqual(split.ownFundingTxids, ["f1", "f2"])
        XCTAssertEqual(PaymentLinkActivity.match(transactionId: "f2", isIncoming: false, records: [split])?.kind, .funding)
        XCTAssertNil(PaymentLinkActivity.match(transactionId: "f2", isIncoming: true, records: [split]))
        // A txid saved by an older build, or found by address: that one only.
        XCTAssertEqual(open(.sent, .pending, fundingTxid: "f9").ownFundingTxids, ["f9"])
        XCTAssertEqual(open(.sent, .notFunded, fundingTxid: nil).ownFundingTxids, [])

        let both = [tx("f2", .outgoing, at: 900), tx("f1", .outgoing, at: 900), tx("other", .outgoing, at: 800)]
        let links = TransactionListLogic.filter(both, type: .links, receivingIndex: nil, search: "", linkRecords: [split])
        XCTAssertEqual(links.map(\.id), ["f1"])
        XCTAssertEqual(TransactionListLogic.filter(both, type: .all, receivingIndex: nil, search: "", linkRecords: [split]).count, 3)
        // Only the second one shown: that row stands for the link.
        XCTAssertEqual(TransactionListLogic.filter([both[0]], type: .links, receivingIndex: nil, search: "", linkRecords: [split]).map(\.id), ["f2"])
        XCTAssertTrue(TransactionListLogic.openSentWithoutRow([split], transactions: [both[0]], type: .links, receivingIndex: nil, search: "",
                                                              asOf: nil, activeWalletId: "w1", walletIds: ["w1"]).isEmpty)

        // One failed, one live: funded.
        let oneFailed = [tx("f1", .outgoing, at: 900, status: .failed), tx("f2", .outgoing, at: 900, status: .pending)]
        XCTAssertTrue(PaymentLinksStatusChecker.fundingUpdates(sent: [split], activeWalletId: "w1", transactions: oneFailed).isEmpty)
        let gone = [tx("f1", .outgoing, at: 900, status: .failed), tx("f2", .outgoing, at: 900, status: .failed)]
        let failed = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(sent: [split], activeWalletId: "w1", transactions: gone).first)
        XCTAssertEqual(failed.fundingFailed, true)
        XCTAssertEqual(failed.status, .notFunded)

        // Adoption by attempt: the live transaction.
        var hidden = open(.sent, .notFunded, id: "hidden", fundingTxid: nil)
        hidden.attemptTxids = ["f1", "f2"]
        let adopted = try XCTUnwrap(PaymentLinksStatusChecker.fundingUpdates(sent: [hidden], activeWalletId: "w1", transactions: oneFailed).first)
        XCTAssertEqual(adopted.fundingTxid, "f2")
        XCTAssertEqual(adopted.status, .pending)
        XCTAssertNil(adopted.fundingFailed)
        // The scan floor: a block of either transaction.
        func row(_ id: String, height: UInt64?) -> MoneroTransaction {
            MoneroTransaction(id: id, type: .outgoing, amount: 1, fee: 0, address: "", timestamp: Date(), confirmations: nil,
                              status: height == nil ? .pending : .confirmed, memo: nil, blockHeight: height)
        }
        var unscanned = split
        unscanned.fundingHeight = nil
        XCTAssertEqual(PaymentLinksStatusChecker.fundingHeight(of: unscanned, in: [row("f1", height: nil), row("f2", height: 3_000)]), 3_000)
        XCTAssertEqual(PaymentLinksStatusChecker.fundingHeight(of: unscanned, in: [row("f1", height: 2_990), row("f2", height: 3_000)]), 2_990)
    }
}
