import XCTest
@testable import MoneroOne

/// `monero:` links (strict) and scanned QR codes (lenient).
@MainActor
final class MoneroPaymentURITests: XCTestCase {

    /// The Monero General Fund's public address (mainnet, standard).
    private let address = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

    private func link(_ raw: String) throws -> MoneroPaymentURI {
        try MoneroPaymentURI.parseLink(raw)
    }

    private func assertLinkFails(_ raw: String, with expected: MoneroPaymentURI.ParseError,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try link(raw), file: file, line: line) { error in
            XCTAssertEqual(error as? MoneroPaymentURI.ParseError, expected, file: file, line: line)
        }
    }

    // MARK: - Strict link reader

    func testAddressOnly() throws {
        XCTAssertEqual(try link("monero:\(address)"), MoneroPaymentURI(address: address, amount: nil))
        XCTAssertEqual(try link("monero:\(address)?"), MoneroPaymentURI(address: address, amount: nil))
    }

    func testAmount() throws {
        XCTAssertEqual(try link("monero:\(address)?tx_amount=0.25").amount, "0.25")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=12").amount, "12")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=0.000000000001").amount, "0.000000000001")
    }

    func testAmountFormsWallet2Accepts() throws {
        XCTAssertEqual(try link("monero:\(address)?tx_amount=.5").amount, "0.5")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=1.").amount, "1")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=1.500000000000000").amount, "1.5")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=007.10").amount, "7.1")
        XCTAssertEqual(try link("monero:\(address)?tx_amount=1%2E5").amount, "1.5")
    }

    func testZeroAmountMeansNoAmount() throws {
        XCTAssertNil(try link("monero:\(address)?tx_amount=0").amount)
        XCTAssertNil(try link("monero:\(address)?tx_amount=0.000").amount)
    }

    func testSchemeCaseAndSlashes() throws {
        XCTAssertEqual(try link("MONERO:\(address)?tx_amount=1").amount, "1")
        XCTAssertEqual(try link("Monero:\(address)").address, address)
        XCTAssertEqual(try link("monero://\(address)?tx_amount=2").address, address)
    }

    /// Free-text fields are read past and dropped: the result has no place
    /// to keep them, so the send flow cannot show a name the link chose.
    func testRecipientNameAndDescriptionAreDropped() throws {
        let uri = try link("monero:\(address)?recipient_name=Monero%20One%20Support&tx_amount=2&tx_description=Refund")
        XCTAssertEqual(uri, MoneroPaymentURI(address: address, amount: "2"))
    }

    func testUnknownParametersAndEmptySegmentsAreIgnored() throws {
        XCTAssertEqual(try link("monero:\(address)?foo=bar&tx_amount=3&").amount, "3")
        XCTAssertEqual(try link("monero:\(address)?&&tx_amount=3").amount, "3")
    }

    func testIntegratedAddressLength() throws {
        let integrated = "4" + String(repeating: "A", count: 105)
        XCTAssertEqual(try link("monero:\(integrated)").address, integrated)
    }

    func testOtherSchemesAndBareAddressesAreRefused() {
        assertLinkFails(address, with: .notMoneroURI)
        assertLinkFails("bitcoin:\(address)", with: .notMoneroURI)
        assertLinkFails("monero:", with: .notMoneroURI)
        assertLinkFails("https://monero.one", with: .notMoneroURI)
    }

    func testBadAddressesAreRefused() {
        assertLinkFails("monero:44AFF", with: .invalidAddress)
        assertLinkFails("monero:?tx_amount=1", with: .invalidAddress)
        // "0", "O", "I" and "l" are not base58.
        assertLinkFails("monero:0" + address.dropFirst(), with: .invalidAddress)
        assertLinkFails("monero:\(address)0", with: .invalidAddress)
        assertLinkFails("monero:\(address)/?tx_amount=1", with: .invalidAddress)
    }

    func testBadAmountsAreRefused() {
        for amount in ["", "abc", "-1", "+1", "1e3", "1,5", "1.2.3", " 1", "0x10",
                       "1.0000000000001", "18446745", "٣"] {
            assertLinkFails("monero:\(address)?tx_amount=\(amount)", with: .invalidAmount)
        }
    }

    func testLargestAmountIsAccepted() throws {
        XCTAssertEqual(try link("monero:\(address)?tx_amount=18446744.073709551615").amount, "18446744.073709551615")
        assertLinkFails("monero:\(address)?tx_amount=18446744.073709551616", with: .invalidAmount)
    }

    func testPaymentIDIsRefused() {
        let pid = String(repeating: "ab", count: 32)
        assertLinkFails("monero:\(address)?tx_payment_id=\(pid)&tx_amount=1", with: .paymentIDUnsupported)
    }

    func testMalformedParametersAreRefused() {
        assertLinkFails("monero:\(address)?tx_amount", with: .malformedParameter)
        assertLinkFails("monero:\(address)?=1", with: .malformedParameter)
        assertLinkFails("monero:\(address)?tx_amount=1&tx_amount=2", with: .duplicateParameter("tx_amount"))
    }

    // MARK: - Lenient scanner reader

    func testScannedBareAddressIsTrimmed() {
        XCTAssertEqual(MoneroPaymentURI.parseScanned("  \(address)\n"), MoneroPaymentURI(address: address, amount: nil))
    }

    func testScannedURIKeepsAddressWhenAmountIsBad() {
        XCTAssertEqual(MoneroPaymentURI.parseScanned("monero:\(address)?tx_amount=abc"),
                       MoneroPaymentURI(address: address, amount: nil))
        XCTAssertEqual(MoneroPaymentURI.parseScanned("monero:\(address)?tx_amount=abc&tx_amount=2"),
                       MoneroPaymentURI(address: address, amount: "2"))
    }

    func testScannedURIIgnoresEverythingElse() {
        let pid = String(repeating: "ab", count: 32)
        XCTAssertEqual(MoneroPaymentURI.parseScanned("MONERO:\(address)?tx_payment_id=\(pid)&bad&tx_amount=.5&recipient_name=x"),
                       MoneroPaymentURI(address: address, amount: "0.5"))
    }

    /// The scanner never refuses: text that is not Monero goes to the
    /// address field, where the send flow marks it invalid.
    func testScannedOtherTextBecomesTheAddress() {
        XCTAssertEqual(MoneroPaymentURI.parseScanned("hello").address, "hello")
    }

    // MARK: - Network check and hold time

    /// The parser leaves the address as wallet2 needs it, and the network
    /// check in `openPaymentLink` refuses a mainnet link on testnet.
    func testParsedAddressPassesWallet2OnItsNetworkOnly() throws {
        let parsed = try link("monero:\(address)?tx_amount=1").address
        XCTAssertTrue(MoneroWallet.isValidAddress(parsed, networkType: .mainnet))
        XCTAssertFalse(MoneroWallet.isValidAddress(parsed, networkType: .testnet))
    }

    func testHeldLinkExpires() {
        let received = Date(timeIntervalSince1970: 1_789_900_000)
        let request = WalletManager.PaymentRequest(address: address, amount: "1", receivedAt: received)
        let lifetime = WalletManager.paymentRequestLifetime

        XCTAssertEqual(WalletManager.freshPaymentRequest(request, now: received.addingTimeInterval(lifetime - 1)), request)
        XCTAssertNil(WalletManager.freshPaymentRequest(request, now: received.addingTimeInterval(lifetime)))
        XCTAssertNil(WalletManager.freshPaymentRequest(nil, now: received))
    }
}
