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
}
