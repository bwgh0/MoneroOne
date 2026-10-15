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

    // MARK: - Funding row status line

    func testFundingStatusLine() {
        let line = PaymentLinkActivity.fundingStatusLine
        XCTAssertEqual(line(.created, false, nil), "Waiting to be claimed")
        XCTAssertEqual(line(.notFunded, false, nil), "Waiting to be claimed")
        XCTAssertEqual(line(.pending, false, 3), "Waiting to be claimed")
        XCTAssertEqual(line(.pending, false, 10), "Ready to claim")
        XCTAssertEqual(line(.ready, false, 12), "Ready to claim")
        XCTAssertEqual(line(.ready, true, 12), "Expired")
        XCTAssertEqual(line(.claimed, true, nil), "Claimed")
        XCTAssertEqual(line(.reclaimed, false, nil), "Reclaimed")
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(
            PaymentLinkActivity.accessibilityLabel(title: "Sent by Link", isIncoming: false, amountSpoken: "0.5 XMR",
                                                   statusLine: "Waiting to be claimed", date: "2 hr. ago", transactionStatus: "Confirmed"),
            "Sent by Link, minus 0.5 XMR, Waiting to be claimed, 2 hr. ago, Confirmed"
        )
        XCTAssertEqual(
            PaymentLinkActivity.accessibilityLabel(title: "Received by Link", isIncoming: true, amountSpoken: "0.25 XMR",
                                                   statusLine: nil, date: "1 min. ago", transactionStatus: "Pending"),
            "Received by Link, plus 0.25 XMR, 1 min. ago, Pending"
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
        func row(_ display: PaymentLinkDisplay) -> String {
            PaymentLinkActivity.fundingStatusLine(status: display.status, isExpired: display.isExpired, confirmations: display.confirmations)
        }
        var stale = record(.sent, status: .pending, fundingTxid: "fund")
        stale.confirmations = 2
        stale.lastCheckedAt = Date(timeIntervalSinceNow: -3600)

        let ready = display(stale, funding: 10)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.label, "Ready")
        XCTAssertEqual(row(ready), "Ready to claim")
        XCTAssertTrue(ready.canReclaim)

        let young = display(stale, funding: 9)
        XCTAssertEqual(young.status, .pending)
        XCTAssertEqual(young.label, "Pending 9/10")
        XCTAssertEqual(row(young), "Waiting to be claimed")
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
        XCTAssertEqual(row(expired), "Expired")
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

    // MARK: - Open links (balance card lines, Open Links group)

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
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: 30_000_000_000, count: 1), "0.0300 XMR to claim")
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: nil, count: 1), "1 link to claim")
        XCTAssertEqual(OpenPaymentLinks.claimLineText(amount: nil, count: 2), "2 links to claim")
    }

    func testOpenLinksGoMostUrgentFirst() {
        XCTAssertEqual(OpenPaymentLinks.kind(role: .received, status: .pending, isExpired: false, confirmations: 2), .toClaim)
        XCTAssertEqual(OpenPaymentLinks.kind(role: .sent, status: .ready, isExpired: true, confirmations: 12), .expired)
        XCTAssertEqual(OpenPaymentLinks.kind(role: .sent, status: .pending, isExpired: false, confirmations: 3), .waiting)
        XCTAssertEqual(OpenPaymentLinks.kind(role: .sent, status: .pending, isExpired: false, confirmations: 10), .ready)
        XCTAssertEqual(OpenPaymentLinks.kind(role: .sent, status: .ready, isExpired: false, confirmations: nil), .ready)

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        func item(_ id: String, _ kind: OpenPaymentLinks.Kind, _ date: Date) -> OpenPaymentLinks.Item {
            var r = open(kind == .toClaim ? .received : .sent, .pending, id: id)
            r.createdAt = date
            return OpenPaymentLinks.Item(record: r, kind: kind)
        }
        let ordered = OpenPaymentLinks.ordered([
            item("ready", .ready, newer),
            item("waitingOld", .waiting, older),
            item("waitingNew", .waiting, newer),
            item("expired", .expired, older),
            item("claim", .toClaim, older),
        ])
        XCTAssertEqual(ordered.map(\.record.id), ["claim", "expired", "waitingNew", "waitingOld", "ready"])
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
