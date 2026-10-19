import XCTest
@testable import MoneroOne

/// Settings > Contact Support: the mail names the app and phone, and
/// opens in the composer, the default mail app or one dialog.
final class SupportMailTests: XCTestCase {

    func testBodyLeavesRoomToWriteThenListsAppAndDeviceFacts() {
        XCTAssertEqual(
            SupportMail.body(
                version: "1.1.0", build: "11",
                systemName: "iOS", systemVersion: "27.0.1",
                model: "iPhone18,1"
            ),
            "\n\n----------\nMonero One 1.1.0 (11)\niOS 27.0.1\niPhone18,1"
        )
    }

    func testComposerWhenAppleMailHasAnAccount() {
        XCTAssertEqual(SupportMail.route(canSendMail: true, canOpenMailto: true), .composer)
        XCTAssertEqual(SupportMail.route(canSendMail: true, canOpenMailto: false), .composer)
    }

    func testDefaultMailAppWhenAppleMailHasNoAccount() {
        XCTAssertEqual(SupportMail.route(canSendMail: false, canOpenMailto: true), .mailApp)
    }

    func testOneDialogWhenNoAppOpensMailto() {
        XCTAssertEqual(SupportMail.route(canSendMail: false, canOpenMailto: false), .noMailApp)
    }

    func testMailtoCarriesAddressSubjectAndBody() throws {
        let body = SupportMail.body(
            version: "1.1.0", build: "11",
            systemName: "iOS", systemVersion: "27.0.1",
            model: "iPhone18,1"
        )
        let url = try XCTUnwrap(SupportMail.mailtoURL(body: body))
        XCTAssertEqual(url.scheme, "mailto")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "support@monero.one")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["subject"], "Monero One iOS - Feedback")
        XCTAssertEqual(items["body"], body)
        XCTAssertEqual(items.count, 2)
    }

    func testMailtoKeepsQuerySeparatorsInsideTheBody() throws {
        let body = "a&b=c+d?e#f"
        let url = try XCTUnwrap(SupportMail.mailtoURL(body: body))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, body)
    }
}
