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
        XCTAssertEqual(rows(.all), [])
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
}
