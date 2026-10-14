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
        XCTAssertEqual(PaymentLinkActivity(kind: .funding, record: record(.sent)).title, "Payment link")
        XCTAssertEqual(PaymentLinkActivity(kind: .reclaim, record: record(.sent)).title, "Link reclaimed")
        XCTAssertEqual(PaymentLinkActivity(kind: .claim, record: record(.received)).title, "Claimed link")
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
            PaymentLinkActivity.accessibilityLabel(title: "Payment link", isIncoming: false, amountSpoken: "0.5 XMR",
                                                   statusLine: "Waiting to be claimed", date: "2 hr. ago", transactionStatus: "Confirmed"),
            "Payment link, minus 0.5 XMR, Waiting to be claimed, 2 hr. ago, Confirmed"
        )
        XCTAssertEqual(
            PaymentLinkActivity.accessibilityLabel(title: "Claimed link", isIncoming: true, amountSpoken: "0.25 XMR",
                                                   statusLine: nil, date: "1 min. ago", transactionStatus: "Pending"),
            "Claimed link, plus 0.25 XMR, 1 min. ago, Pending"
        )
    }

    // MARK: - Received links at the top of Activity

    func testPendingStateFromTheRecord() {
        let state = PendingPaymentLinks.state
        XCTAssertEqual(state(record(.received, status: .created), 500, Date()), .unchecked)
        XCTAssertEqual(state(record(.received, status: .notFunded), 500, Date()), .noMoney)
        XCTAssertEqual(state(record(.received, status: .ready), 0, Date()), .ready)
    }

    /// Your links says the same as the pinned row for a received link.
    @MainActor
    func testReceivedLinksInYourLinksMatchThePinnedRow() {
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

    // MARK: - Send: Your links

    func testOpenCountCountsLinksThatMayHoldMoney() {
        var unchecked = record(.received, id: "r1", status: .created)
        unchecked.secret = "000102030405060708090a0b0c0d0e0f"
        let records = [
            record(.sent, id: "s1", status: .pending),
            record(.sent, id: "s2", status: .ready),
            record(.sent, id: "s3", status: .created),
            record(.sent, id: "s4", status: .notFunded),
            record(.sent, id: "s5", status: .claimed),
            record(.sent, id: "s6", status: .reclaimed),
            unchecked,
            record(.received, id: "r2", status: .created),
            record(.received, id: "r3", status: .pending),
            record(.received, id: "r4", status: .claimed),
        ]
        // s1, s2, r1 (unchecked with its secret), r3.
        XCTAssertEqual(YourLinksRow.openCount(records), 4)
        XCTAssertEqual(YourLinksRow.openCount([]), 0)
    }
}
