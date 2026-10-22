import MoneroKit
import Network
import XCTest
@testable import MoneroOne

// OpenAlias send spec, sections 8.1 and 8.2. No test here calls the wallet2
// resolver. Only the live loop reaches the network, and it runs only when
// asked: the bridge tests use a fake DoH transport, and the SOCKS test and
// the kit tests use listeners on the IPv4 loopback.

// MARK: - Fixtures

private enum Fixture {
    /// donate.getmonero.org, as served on 2026-09-27.
    static let getmoneroAddress = "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
    static let getmoneroRecords = [
        "oa1:btc recipient_address=1KTexdemPdxSBcG55heUuTjDRYqbC5ZL8H; recipient_name=Monero Development; tx_description=Donation to Monero Core Team;",
        "oa1:xmr recipient_address=\(getmoneroAddress); recipient_name=Monero Development; tx_description=Donation to Monero Core Team;",
    ]

    /// openalias.org, as served on 2026-09-27.
    static let openaliasAddress = "46BeWrHpwXmHDpDEUmZBWZfoQpdc6HaERCNmx1pEYL2rAcuwufPN9rXHHtyUA4QVy66qeFQkn6sfK8aHYjA3jk3o1Bv16em"
    static let openaliasRecords = [
        "oa1:xmr recipient_address=\(openaliasAddress); recipient_name=Monero Development; tx_description=Donation to Monero Core Team;",
        "v=spf1 include:spf.improvmx.com ~all",
        "oa1:btc recipient_address=1FhnVJi2V1k4MqXm2nHoEbY5LV7FPai7bb; recipient_name=Monero Development; tx_description=Donation to Monero Core Team;",
    ]

    /// Valid on testnet only, for the fake check.
    static let testnetAddress = "9" + String(repeating: "t", count: 94)

    /// The fake address check: the two fixture addresses are valid on
    /// mainnet, an address that starts with 9 is valid on testnet only.
    static func check(_ address: String) -> AddressCheck {
        if address == getmoneroAddress || address == openaliasAddress { return .valid }
        if address.hasPrefix("9") { return .otherNetwork }
        return .invalid
    }

    /// TXT RDATA for one record: character-strings of 255 bytes at most.
    static func rdataHex(_ text: String) -> String {
        rdataHex(strings: stride(from: 0, to: max(text.utf8.count, 1), by: 255).map { start in
            Array(Array(text.utf8)[start..<min(start + 255, text.utf8.count)])
        })
    }

    static func rdataHex(strings: [[UInt8]]) -> String {
        var bytes: [UInt8] = []
        for string in strings {
            bytes.append(UInt8(string.count))
            bytes += string
        }
        return hex(bytes)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The kit JSON of section 3.4.
    static func answer(status: String = "ok", rcode: Int = 0, havedata: Bool = true, nxdomain: Bool = false,
                       secure: Bool = true, bogus: Bool = false, records: [String]) -> String {
        let object: [String: Any] = [
            "status": status, "rcode": rcode, "havedata": havedata, "nxdomain": nxdomain,
            "secure": secure, "bogus": bogus, "why_bogus": bogus ? "signature missing" : "",
            "records": records.map(rdataHex),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - Fake DoH transport

/// Records every call and answers with `handler`.
private final class FakeTransport: DohTransport, @unchecked Sendable {
    typealias Handler = @Sendable (Data, URL) async throws -> DohHTTPReply

    private let lock = NSLock()
    private var recorded: [(message: Data, server: URL)] = []
    private let handler: Handler

    init(handler: @escaping Handler = FakeTransport.echo) {
        self.handler = handler
    }

    var calls: [(message: Data, server: URL)] { lock.withLock { recorded } }

    func post(_ message: Data, to server: URL) async throws -> DohHTTPReply {
        lock.withLock { recorded.append((message, server)) }
        return try await handler(message, server)
    }

    func invalidate() {}

    /// A good answer: the query with the QR bit set.
    static let echo: Handler = { message, _ in
        var bytes = [UInt8](message)
        bytes[2] |= 0x80
        return DohHTTPReply(status: 200, contentType: "application/dns-message", body: Data(bytes))
    }

    static let fail: Handler = { _, _ in throw URLError(.cannotConnectToHost) }
}

// MARK: - Loopback sockets

/// Blocking BSD sockets on the IPv4 loopback, for tests only.
private enum Loopback {
    struct SocketError: Error {
        let code: Int32
    }

    static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        IPv4Address.loopback.rawValue.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyMemory(from: source) }
        }
        return address
    }

    static func connect(port: UInt16, timeoutSeconds: Int = 5) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(code: errno) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = address(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError(code: code)
        }
        return fd
    }

    /// A socket bound to a free loopback port. With `listen`, it accepts
    /// connections into its backlog and never answers.
    static func bind(listen: Bool) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(code: errno) }
        var address = address(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError(code: code)
        }
        if listen { Darwin.listen(fd, 8) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    static func write(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard sent > 0 else { throw SocketError(code: errno) }
            offset += sent
        }
    }

    static func sendFrame(_ fd: Int32, _ message: [UInt8]) throws {
        try write(fd, [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message)
    }

    /// Nil at the end of the stream.
    static func read(_ fd: Int32, count: Int) throws -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes[offset...].withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if received == 0 { return nil }
            guard received > 0 else { throw SocketError(code: errno) }
            offset += received
        }
        return bytes
    }

    static func readFrame(_ fd: Int32) throws -> [UInt8]? {
        guard let header = try read(fd, count: 2) else { return nil }
        return try read(fd, count: Int(header[0]) << 8 | Int(header[1]))
    }
}

/// A DNS query for a TXT record, with RD and CD set.
private func dnsQuery(id: UInt16, name: String = "donate.getmonero.org") -> [UInt8] {
    var query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x10, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") {
        query.append(UInt8(label.utf8.count))
        query += Array(label.utf8)
    }
    query += [0, 0, 16, 0, 1]
    return query
}

private func messageID(_ bytes: [UInt8]) -> UInt16 {
    UInt16(bytes[0]) << 8 | UInt16(bytes[1])
}

// MARK: - Pure logic, pins and the lookup model

@MainActor
final class OpenAliasTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OpenAliasTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: Classification (section 4.1)

    private func assertName(_ input: String, query: String, display: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(OpenAlias.classify(input), .name(OpenAliasName(display: display, query: query)),
                       input, file: file, line: line)
    }

    func testClassifyNames() {
        assertName("donate@getmonero.org", query: "donate.getmonero.org", display: "donate@getmonero.org")
        assertName(" Donate@GetMonero.org ", query: "donate.getmonero.org", display: "donate@getmonero.org")
        assertName("donate.getmonero.org", query: "donate.getmonero.org", display: "donate.getmonero.org")
        assertName("openalias.org.", query: "openalias.org", display: "openalias.org")
        assertName("_pay.example.com", query: "_pay.example.com", display: "_pay.example.com")
        assertName("pay.xn--mnchen-3ya.de", query: "pay.xn--mnchen-3ya.de", display: "pay.xn--mnchen-3ya.de")
        assertName("pay.example.xn--p1ai", query: "pay.example.xn--p1ai", display: "pay.example.xn--p1ai")
    }

    func testClassifyAddresses() {
        XCTAssertEqual(OpenAlias.classify(Fixture.openaliasAddress), .address(Fixture.openaliasAddress))
        XCTAssertEqual(OpenAlias.classify(" \(Fixture.openaliasAddress)\n"), .address(Fixture.openaliasAddress))
        let link = "monero:\(Fixture.openaliasAddress)?tx_amount=1"
        XCTAssertEqual(OpenAlias.classify(link), .address(link))
        XCTAssertEqual(OpenAlias.classify("joe"), .address("joe"))
        XCTAssertEqual(OpenAlias.classify(""), .empty)
        XCTAssertEqual(OpenAlias.classify(" \n "), .empty)
    }

    func testClassifyReserved() {
        for input in ["monero.one", "a.b.monero.one", "MONERO.ONE"] {
            XCTAssertEqual(OpenAlias.classify(input), .reserved, input)
        }
    }

    func testUsernameFormsRouteToTheSignatureVerifier() {
        for input in ["@Joe", "joe@monero.one", "joe.monero.one"] {
            assertName(input, query: "joe.monero.one", display: "@joe")
            if case .name(let name) = OpenAlias.classify(input) { XCTAssertTrue(name.isUsername) }
        }
        assertName("@work.Joe", query: "work.joe.monero.one", display: "@work.joe")
        assertName("@xmr_garden_club", query: "xmr_garden_club.monero.one", display: "@xmr_garden_club")
        for invalid in ["@jo", "@abcdefghijklmnop", "@joe__smith", "@jóe", "@@joe", "@joe/path"] {
            XCTAssertEqual(OpenAlias.classify(invalid), .invalidName)
        }
    }

    func testClassifyOperatorNames() {
        // donate@monero.one is Monero One's own name: it resolves like any other.
        assertName("donate@monero.one", query: "donate.monero.one", display: "donate@monero.one")
        assertName(" DONATE@Monero.One ", query: "donate.monero.one", display: "donate@monero.one")
        assertName("donate@monero.one.", query: "donate.monero.one", display: "donate@monero.one")
        // Operator names still require the explicit external form.
        for input in ["donate.monero.one", "donate@pay.monero.one", "@donate"] {
            XCTAssertEqual(OpenAlias.classify(input), .reserved, input)
        }
    }

    func testMoneroOneLogoOnlyForOperatorNames() {
        func summary(_ input: String, recipientName: String? = nil,
                     dnssec: DnssecStatus = .valid) -> OpenAliasSummary? {
            guard case .name(let name) = OpenAlias.classify(input) else { return nil }
            return OpenAliasSummary(name: name, address: Fixture.getmoneroAddress, dnssec: dnssec, pin: .none,
                                    recipientName: recipientName)
        }
        XCTAssertEqual(summary("donate@monero.one", recipientName: "Monero One")?.showsMoneroOneLogo, true)
        XCTAssertEqual(summary("Donate@Monero.one")?.showsMoneroOneLogo, true)
        // A record that calls itself Monero One gets a monogram.
        XCTAssertEqual(summary("donate@getmonero.org", recipientName: "Monero One")?.showsMoneroOneLogo, false)
        XCTAssertEqual(summary("donate@monero.one.example.com", recipientName: "Monero One")?.showsMoneroOneLogo, false)
        XCTAssertEqual(summary("donate@monero.on")?.showsMoneroOneLogo, false)
        XCTAssertFalse(OpenAlias.isOperatorName("joe@monero.one"))
        XCTAssertFalse(OpenAlias.isOperatorName("donate.monero.one"))
    }

    func testMoneroOneLogoNeedsDnssec() {
        guard case .name(let name) = OpenAlias.classify("donate@monero.one") else {
            return XCTFail("donate@monero.one resolves as a name")
        }
        let valid = OpenAliasSummary(name: name, address: Fixture.getmoneroAddress, dnssec: .valid, pin: .none,
                                     recipientName: "Monero One")
        XCTAssertTrue(valid.showsMoneroOneLogo)
        // Unsigned: the monogram, like any other name.
        let unsigned = OpenAliasSummary(name: name, address: Fixture.getmoneroAddress, dnssec: .off, pin: .none,
                                        recipientName: "Monero One")
        XCTAssertFalse(unsigned.showsMoneroOneLogo)
        XCTAssertEqual(unsigned.initials, "MO")
    }

    func testClassifyInvalidNames() {
        let inputs = [
            "@ab.org", "joe@", "a@b@c.com",
            "d\u{043E}nate@getmonero.org",  // Cyrillic "о"
            "-pay.example.com", "a..b.com", "pay.example.123",
            "pay.onion", "joe@localhost",
            "donate.getmonero.org:443", "pay.example.com/x",
            String(repeating: "a", count: 64) + ".example.com",
            Array(repeating: String(repeating: "a", count: 63), count: 3).joined(separator: ".") + "." + String(repeating: "b", count: 58) + ".com",
        ]
        XCTAssertEqual(inputs.last?.count, 254)
        for input in inputs {
            XCTAssertEqual(OpenAlias.classify(input), .invalidName, input)
        }
        // The longest name that passes: 63-character labels, 253 in all.
        let longest = Array(repeating: String(repeating: "a", count: 63), count: 3).joined(separator: ".") + "." + String(repeating: "b", count: 57) + ".com"
        XCTAssertEqual(longest.count, 253)
        if case .name = OpenAlias.classify(longest) {} else { XCTFail("63-character labels pass") }
    }

    // MARK: TXT decode (section 4.2)

    func testDecodeOneString() {
        XCTAssertEqual(OpenAlias.decodeTXT(hex: Fixture.rdataHex("oa1:xmr a=b;")), "oa1:xmr a=b;")
    }

    func testDecodeTwoStringsJoined() {
        let hex = Fixture.rdataHex(strings: [Array("oa1:xmr recipient_".utf8), Array("address=abc;".utf8)])
        XCTAssertEqual(OpenAlias.decodeTXT(hex: hex), "oa1:xmr recipient_address=abc;")
        // A record of more than 255 bytes arrives in two strings.
        let long = "oa1:xmr recipient_name=" + String(repeating: "x", count: 300) + ";"
        XCTAssertEqual(OpenAlias.decodeTXT(hex: Fixture.rdataHex(long)), long)
    }

    func testDecodeDropsBadRecords() {
        XCTAssertNil(OpenAlias.decodeTXT(hex: Fixture.hex([10] + Array("short".utf8))), "length past the end")
        XCTAssertNil(OpenAlias.decodeTXT(hex: ""), "empty RDATA")
        XCTAssertNil(OpenAlias.decodeTXT(hex: Fixture.rdataHex(strings: [[0x6F, 0x61, 0xFF]])), "bad UTF-8")
    }

    // MARK: OA1 parse and select (sections 4.3 and 4.4)

    private func select(_ texts: [String], dnssec: DnssecStatus = .valid) -> Result<OpenAliasResult, OpenAliasFailure> {
        OpenAlias.select(texts.compactMap(OpenAlias.parseRecord), dnssec: dnssec, check: Fixture.check)
    }

    private func record(_ fields: String) -> String {
        "oa1:xmr " + fields
    }

    func testGetmoneroFixture() {
        XCTAssertEqual(select(Fixture.getmoneroRecords),
                       .success(OpenAliasResult(address: Fixture.getmoneroAddress, recipientName: "Monero Development",
                                                txDescription: "Donation to Monero Core Team", dnssec: .valid)))
    }

    func testOpenaliasFixture() {
        XCTAssertEqual(select(Fixture.openaliasRecords, dnssec: .off),
                       .success(OpenAliasResult(address: Fixture.openaliasAddress, recipientName: "Monero Development",
                                                txDescription: "Donation to Monero Core Team", dnssec: .off)))
    }

    func testPrefixRules() {
        XCTAssertEqual(try select(["OA1:XMR recipient_address=\(Fixture.getmoneroAddress);"]).get().address, Fixture.getmoneroAddress)
        XCTAssertEqual(select(["oa1:xmrfoo recipient_address=\(Fixture.getmoneroAddress);"]), .failure(.noRecord))
        XCTAssertNil(OpenAlias.parseRecord("oa1:xmrfoo recipient_address=\(Fixture.getmoneroAddress);"))
        XCTAssertNil(OpenAlias.parseRecord("v=spf1 include:spf.improvmx.com ~all"))
    }

    func testQuotedValue() {
        let text = record(#"recipient_address=\#(Fixture.getmoneroAddress); recipient_name="Monero; \"Dev\""; tx_description=x;"#)
        let parsed = OpenAlias.parseRecord(text)
        XCTAssertEqual(parsed?.addresses, [Fixture.getmoneroAddress])
        XCTAssertEqual(parsed?.recipientName, #"Monero; "Dev""#)
        XCTAssertEqual(try select([text]).get().recipientName, #"Monero; "Dev""#)
    }

    func testMissingClosingQuoteSkipsRecord() {
        let text = record(#"recipient_address=\#(Fixture.getmoneroAddress); recipient_name="Monero Dev;"#)
        XCTAssertNil(OpenAlias.parseRecord(text))
        XCTAssertEqual(select([text]), .failure(.noRecord))
    }

    func testSeveralRecords() {
        let same = record("recipient_address=\(Fixture.getmoneroAddress);")
        XCTAssertEqual(try select([same, same]).get().address, Fixture.getmoneroAddress)
        let other = record("recipient_address=\(Fixture.openaliasAddress);")
        XCTAssertEqual(select([same, other]), .failure(.severalAddresses))
        let both = record("recipient_address=\(Fixture.getmoneroAddress); recipient_address=\(Fixture.openaliasAddress);")
        XCTAssertEqual(select([both]), .failure(.severalAddresses))
    }

    func testNoAddress() {
        XCTAssertEqual(select([record("recipient_name=Monero Development;")]), .failure(.noRecord))
        XCTAssertEqual(select([]), .failure(.noRecord))
    }

    func testPaymentIDAndAmount() {
        let withID = record("recipient_address=\(Fixture.getmoneroAddress); tx_payment_id=0123456789abcdef;")
        XCTAssertEqual(select([withID]), .failure(.paymentID))
        let withAmount = record("recipient_address=\(Fixture.getmoneroAddress); tx_amount=1.5;")
        XCTAssertEqual(try select([withAmount]).get().address, Fixture.getmoneroAddress)
    }

    func testAddressChecks() {
        XCTAssertEqual(select([record("recipient_address=4notAnAddress;")]), .failure(.invalidAddress))
        XCTAssertEqual(select([record("recipient_address=\(Fixture.testnetAddress);")]), .failure(.wrongNetwork))
    }

    func testDifferentNamesGiveNoName() {
        let first = record("recipient_address=\(Fixture.getmoneroAddress); recipient_name=Alice;")
        let second = record("recipient_address=\(Fixture.getmoneroAddress); recipient_name=Bob;")
        XCTAssertEqual(select([first, second]),
                       .success(OpenAliasResult(address: Fixture.getmoneroAddress, recipientName: nil, dnssec: .valid)))
    }

    func testTxDescription() {
        let first = record("recipient_address=\(Fixture.getmoneroAddress); tx_description=Coffee; tx_description=Tea;")
        XCTAssertEqual(OpenAlias.parseRecord(first)?.txDescription, "Coffee")
        XCTAssertEqual(try select([first]).get().txDescription, "Coffee")

        // Sanitized like the name.
        let hidden = record("recipient_address=\(Fixture.getmoneroAddress); tx_description=Cof\u{202E}fee\n for  you;")
        XCTAssertEqual(try select([hidden]).get().txDescription, "Coffee for you")

        // Records that disagree give no description; a record without one does not count.
        let second = record("recipient_address=\(Fixture.getmoneroAddress); tx_description=Lunch;")
        let none = record("recipient_address=\(Fixture.getmoneroAddress);")
        XCTAssertNil(try select([first, second]).get().txDescription)
        XCTAssertEqual(try select([first, none]).get().txDescription, "Coffee")
        XCTAssertNil(try select([none]).get().txDescription)
    }

    // MARK: Sanitize (section 4.5)

    func testSanitizeName() {
        XCTAssertEqual(OpenAlias.sanitizeName("Mon\u{202E}ero\u{200B} Dev"), "Monero Dev")
        XCTAssertEqual(OpenAlias.sanitizeName("Monero\nDevelopment"), "Monero Development")
        XCTAssertEqual(OpenAlias.sanitizeName("  Monero \t  Dev  "), "Monero Dev")
        let seventy = String(repeating: "abcdefghij", count: 7)
        XCTAssertEqual(OpenAlias.sanitizeName(seventy), String(seventy.prefix(64)) + "…")
        XCTAssertNil(OpenAlias.sanitizeName("\u{0001}\u{0002}\u{200B}"))
    }

    func testSanitizeRemovesInvisibleCharacters() {
        // Bidi override and isolate, zero-width space and joiner, BOM, soft hyphen.
        XCTAssertEqual(OpenAlias.sanitizeName("\u{202E}Mon\u{2066}ero\u{200B}\u{200D} De\u{FEFF}v\u{00AD}"), "Monero Dev")
        // The Hangul filler is a letter, but it draws nothing.
        XCTAssertEqual(OpenAlias.sanitizeName("Monero\u{3164}One"), "MoneroOne")
        XCTAssertNil(OpenAlias.sanitizeName("\u{3164}\u{200B} \u{FEFF}"))
        // Line and paragraph separators are whitespace: one space.
        XCTAssertEqual(OpenAlias.sanitizeName("Monero\u{2028}\u{2029}One"), "Monero One")
        // Accents and other scripts stay.
        XCTAssertEqual(OpenAlias.sanitizeName("Cafe\u{0301} Mon\u{00E9}ro"), "Cafe\u{0301} Mon\u{00E9}ro")
        XCTAssertEqual(OpenAlias.sanitizeName("モネロ 開発"), "モネロ 開発")
    }

    func testSanitizeCaps() {
        let sixtyFour = String(repeating: "a", count: 64)
        XCTAssertEqual(OpenAlias.sanitizeName(sixtyFour), sixtyFour)
        // No space before the "…".
        let spaced = String(repeating: "a", count: 63) + " bbbbbb"
        XCTAssertEqual(OpenAlias.sanitizeName(spaced), String(repeating: "a", count: 63) + "…")
        // The cap counts characters, not scalars.
        let accents = String(repeating: "e\u{0301}", count: 64)
        XCTAssertEqual(OpenAlias.sanitizeName(accents), accents)
        // Descriptions cap at 100.
        let long = String(repeating: "abcdefghij", count: 11)
        XCTAssertEqual(OpenAlias.sanitizeDescription(long), String(long.prefix(100)) + "…")
        XCTAssertEqual(OpenAlias.sanitizeDescription(String(long.prefix(100))), String(long.prefix(100)))
    }

    // MARK: Monogram

    func testInitials() {
        let display = "donate@getmonero.org"
        XCTAssertEqual(OpenAlias.initials(recipientName: "Monero Development", display: display), "MD")
        XCTAssertEqual(OpenAlias.initials(recipientName: "monero  core team", display: display), "MC")
        XCTAssertEqual(OpenAlias.initials(recipientName: "Monero", display: display), "M")
        XCTAssertEqual(OpenAlias.initials(recipientName: "🎉 Party Fund", display: display), "PF")
        XCTAssertEqual(OpenAlias.initials(recipientName: "(Monero) 42 dev", display: display), "MD")
        XCTAssertEqual(OpenAlias.initials(recipientName: "élan vital", display: display), "ÉV")
        // A letter with a two-letter capital stays as it is.
        XCTAssertEqual(OpenAlias.initials(recipientName: "ßar", display: display), "ß")
    }

    func testInitialsFromTheName() {
        XCTAssertEqual(OpenAlias.initials(recipientName: nil, display: "donate@getmonero.org"), "D")
        XCTAssertEqual(OpenAlias.initials(recipientName: "1234 !!", display: "donate@getmonero.org"), "D")
        XCTAssertEqual(OpenAlias.initials(recipientName: nil, display: "getmonero.org"), "G")
        XCTAssertEqual(OpenAlias.initials(recipientName: nil, display: "_pay.example.com"), "P")
        XCTAssertNil(OpenAlias.initials(recipientName: nil, display: "1234@example.com"))
        XCTAssertNil(OpenAlias.initials(recipientName: "42", display: "42.example.com"))
    }

    // MARK: Recipient card

    func testSummaryText() {
        let name = OpenAliasName(display: "donate@getmonero.org", query: "donate.getmonero.org")
        let named = OpenAliasSummary(name: name, address: Fixture.getmoneroAddress, dnssec: .valid, pin: .none,
                                     recipientName: "Monero Development")
        XCTAssertEqual(named.spokenName, "Monero Development, donate@getmonero.org")
        XCTAssertEqual(named.spokenStatus, "DNSSEC valid")
        XCTAssertEqual(named.initials, "MD")

        let bare = OpenAliasSummary(name: name, address: Fixture.getmoneroAddress, dnssec: .off, pin: .same(Date()))
        XCTAssertEqual(bare.spokenName, "donate@getmonero.org")
        XCTAssertEqual(bare.spokenStatus, "DNSSEC off, Same address as your last payment")
        XCTAssertEqual(bare.initials, "D")
    }

    func testNameWrapPoints() {
        XCTAssertEqual(OpenAliasNameText.wrappable("donate@getmonero.org"), "donate@\u{200B}getmonero\u{200B}.org")
        XCTAssertEqual(OpenAliasNameText.wrappable("pay.example.com"), "pay\u{200B}.example\u{200B}.com")
        XCTAssertEqual(OpenAliasNameText.wrappable("x"), "x")
    }

    // MARK: Answer mapping (section 3.7)

    private func map(_ json: String, synthesized: Int = 0, tor: Bool = false) -> Result<OpenAliasResult, OpenAliasFailure> {
        OpenAlias.mapAnswer(json: json, synthesizedCount: synthesized, torOn: tor, check: Fixture.check)
    }

    func testMapParseFailure() {
        XCTAssertEqual(map("not json"), .failure(.network))
        XCTAssertEqual(map("not json", tor: true), .failure(.tor))
    }

    func testMapStatus() {
        XCTAssertEqual(map(#"{"status":"timeout"}"#), .failure(.timeout))
        XCTAssertEqual(map(#"{"status":"error","error":"bad arguments"}"#), .failure(.network))
        XCTAssertEqual(map(#"{"status":"something"}"#), .failure(.network))
        XCTAssertEqual(map(#"{"status":"error","error":"x"}"#, tor: true), .failure(.tor))
    }

    func testMapSynthesizedFailure() {
        let bogus = Fixture.answer(secure: false, bogus: true, records: [])
        XCTAssertEqual(map(bogus, synthesized: 1), .failure(.network))
        XCTAssertEqual(map(bogus, synthesized: 1, tor: true), .failure(.tor))
        let servfail = Fixture.answer(rcode: 2, havedata: false, secure: false, records: [])
        XCTAssertEqual(map(servfail, synthesized: 2), .failure(.network))
    }

    func testMapSynthesizedWithGoodAnswerStands() {
        let good = Fixture.answer(records: Fixture.getmoneroRecords)
        XCTAssertEqual(try map(good, synthesized: 1).get().address, Fixture.getmoneroAddress)
    }

    func testMapBogus() {
        XCTAssertEqual(map(Fixture.answer(secure: false, bogus: true, records: Fixture.getmoneroRecords)), .failure(.dnssecFailed))
    }

    func testMapNoRecord() {
        XCTAssertEqual(map(Fixture.answer(rcode: 3, havedata: false, nxdomain: true, records: [])), .failure(.noRecord))
        XCTAssertEqual(map(Fixture.answer(rcode: 0, havedata: false, nxdomain: true, records: [])), .failure(.noRecord))
        XCTAssertEqual(map(Fixture.answer(havedata: false, records: [])), .failure(.noRecord))
        XCTAssertEqual(map(Fixture.answer(records: [])), .failure(.noRecord))
        XCTAssertEqual(map(Fixture.answer(records: ["v=spf1 include:spf.improvmx.com ~all"])), .failure(.noRecord))
    }

    func testMapOtherRcode() {
        XCTAssertEqual(map(Fixture.answer(rcode: 2, havedata: false, records: [])), .failure(.network))
        XCTAssertEqual(map(Fixture.answer(rcode: 5, havedata: false, records: []), tor: true), .failure(.tor))
    }

    func testMapResolved() {
        XCTAssertEqual(try map(Fixture.answer(records: Fixture.getmoneroRecords)).get(),
                       OpenAliasResult(address: Fixture.getmoneroAddress, recipientName: "Monero Development",
                                       txDescription: "Donation to Monero Core Team", dnssec: .valid))
        XCTAssertEqual(try map(Fixture.answer(secure: false, records: Fixture.openaliasRecords)).get().dnssec, .off)
    }

    // MARK: Pins (section 4.6)

    private var pins: OpenAliasPinStore { OpenAliasPinStore(defaults: defaults) }

    func testPinStates() {
        let query = "donate.getmonero.org"
        XCTAssertEqual(pins.state(query: query, address: Fixture.getmoneroAddress, network: .mainnet), .none)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        pins.record(query: query, address: Fixture.getmoneroAddress, network: .mainnet, at: date)
        XCTAssertEqual(pins.state(query: query, address: Fixture.getmoneroAddress, network: .mainnet), .same(date))
        XCTAssertEqual(pins.state(query: query, address: Fixture.openaliasAddress, network: .mainnet), .changed(date))
        XCTAssertEqual(pins.state(query: query, address: Fixture.getmoneroAddress, network: .testnet), .none)
        XCTAssertNotNil(defaults.string(forKey: "openAliasPins.mainnet"))
    }

    func testPinKeySharedByBothForms() {
        guard case .name(let withAt) = OpenAlias.classify("donate@getmonero.org"),
              case .name(let withDot) = OpenAlias.classify("donate.getmonero.org") else {
            return XCTFail("both forms are names")
        }
        XCTAssertEqual(withAt.query, withDot.query)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        pins.record(query: withAt.query, address: Fixture.getmoneroAddress, network: .mainnet, at: date)
        XCTAssertEqual(pins.state(query: withDot.query, address: Fixture.getmoneroAddress, network: .mainnet), .same(date))
    }

    func testPinCapRemovesOldest() {
        let store = pins
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<OpenAliasPinStore.cap {
            store.record(query: "n\(index).example.com", address: Fixture.getmoneroAddress, network: .mainnet,
                         at: base.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertNotEqual(store.state(query: "n0.example.com", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        store.record(query: "n500.example.com", address: Fixture.getmoneroAddress, network: .mainnet,
                     at: base.addingTimeInterval(1_000))
        XCTAssertEqual(store.state(query: "n0.example.com", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        XCTAssertNotEqual(store.state(query: "n1.example.com", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        XCTAssertNotEqual(store.state(query: "n500.example.com", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        let json = try? JSONSerialization.jsonObject(with: Data(defaults.string(forKey: "openAliasPins.mainnet")!.utf8))
        XCTAssertEqual((json as? [String: Any])?.count, OpenAliasPinStore.cap)
    }

    func testPinClearAll() {
        pins.record(query: "a.example.com", address: Fixture.getmoneroAddress, network: .mainnet)
        pins.record(query: "b.example.com", address: Fixture.testnetAddress, network: .testnet)
        pins.clearAll()
        XCTAssertEqual(pins.state(query: "a.example.com", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        XCTAssertEqual(pins.state(query: "b.example.com", address: Fixture.testnetAddress, network: .testnet), .none)
        XCTAssertNil(defaults.object(forKey: "openAliasPins.mainnet"))
        XCTAssertNil(defaults.object(forKey: "openAliasPins.testnet"))
    }

    // MARK: Lookup model

    /// A resolver with a canned kit answer. The kit call counts itself.
    private final class KitStub: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let json: String
        let delay: TimeInterval
        init(json: String, delay: TimeInterval = 0) {
            self.json = json
            self.delay = delay
        }
        var calls: Int { lock.withLock { count } }
        func lookup() -> String {
            lock.withLock { count += 1 }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return json
        }
    }

    private func makeModel(_ stub: KitStub, typingDelay: Duration = .milliseconds(100),
                           resolvedFeedback: @escaping @MainActor () -> Void = {}) -> (OpenAliasLookupModel, () -> [String]) {
        var resolver = OpenAliasResolver()
        resolver.proxyAddress = { nil }
        resolver.makeTransport = { _ in FakeTransport(handler: FakeTransport.fail) }
        resolver.kitLookup = { _, _, _ in stub.lookup() }
        var announcements: [String] = []
        let model = OpenAliasLookupModel(resolver: resolver, pins: OpenAliasPinStore(defaults: defaults),
                                         typingDelay: typingDelay, announce: { announcements.append($0) },
                                         resolvedFeedback: resolvedFeedback)
        return (model, { announcements })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testModelSubmitResolvesAtOnce() async {
        let stub = KitStub(json: Fixture.answer(records: Fixture.getmoneroRecords))
        let (model, announcements) = makeModel(stub, typingDelay: .seconds(10))
        model.submit("donate@getmonero.org")
        XCTAssertEqual(model.phase, .looking)
        await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary, OpenAliasSummary(
            name: OpenAliasName(display: "donate@getmonero.org", query: "donate.getmonero.org"),
            address: Fixture.getmoneroAddress, dnssec: .valid, pin: .none,
            recipientName: "Monero Development", txDescription: "Donation to Monero Core Team"))
        XCTAssertEqual(announcements(), ["Address found for donate@getmonero.org. DNSSEC valid"])
        XCTAssertEqual(stub.calls, 1)
    }

    func testModelResolveFiresOneHaptic() async {
        var taps = 0
        let stub = KitStub(json: Fixture.answer(records: Fixture.getmoneroRecords))
        let (model, _) = makeModel(stub, typingDelay: .seconds(10), resolvedFeedback: { taps += 1 })
        model.submit("donate@getmonero.org")
        XCTAssertEqual(taps, 0)
        await waitUntil { model.summary != nil }
        XCTAssertEqual(taps, 1)

        // A failed lookup plays none.
        let empty = KitStub(json: Fixture.answer(records: []))
        let (failing, _) = makeModel(empty, typingDelay: .seconds(10), resolvedFeedback: { taps += 1 })
        failing.submit("donate@getmonero.org")
        await waitUntil { failing.phase != .looking }
        XCTAssertEqual(failing.phase, .failed(.noRecord))
        XCTAssertEqual(taps, 1)
    }

    func testModelTypingWaitsForDelay() async {
        let stub = KitStub(json: Fixture.answer(secure: false, records: Fixture.openaliasRecords))
        let (model, _) = makeModel(stub, typingDelay: .milliseconds(300))
        model.textChanged("openalias.org")
        XCTAssertEqual(model.phase, .waiting)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stub.calls, 0)
        await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary?.dnssec, .off)
        XCTAssertEqual(stub.calls, 1)
    }

    func testModelSameQueryKeepsState() async {
        let stub = KitStub(json: Fixture.answer(records: Fixture.getmoneroRecords))
        let (model, _) = makeModel(stub)
        model.submit("donate@getmonero.org")
        await waitUntil { model.summary != nil }
        model.textChanged("donate.getmonero.org ")
        XCTAssertEqual(model.summary?.name.display, "donate.getmonero.org")
        XCTAssertEqual(model.summary?.address, Fixture.getmoneroAddress)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stub.calls, 1)
    }

    func testModelNewTextIgnoresLateResult() async {
        let stub = KitStub(json: Fixture.answer(records: Fixture.getmoneroRecords), delay: 0.4)
        let (model, announcements) = makeModel(stub)
        model.submit("donate@getmonero.org")
        await waitUntil { stub.calls == 1 }
        model.textChanged(Fixture.getmoneroAddress)
        XCTAssertEqual(model.phase, .pendingAddress)
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.phase, .address)
        XCTAssertNil(model.summary)
        XCTAssertTrue(announcements().isEmpty)
    }

    func testModelTrailingDotRestartsDelay() async {
        let stub = KitStub(json: Fixture.answer(secure: false, records: Fixture.openaliasRecords))
        let (model, _) = makeModel(stub, typingDelay: .seconds(1))
        model.textChanged("openalias.org")
        try? await Task.sleep(for: .milliseconds(600))
        model.textChanged("openalias.org.")
        try? await Task.sleep(for: .milliseconds(600))
        // More than one delay after the first change, less after the dot.
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertEqual(stub.calls, 0)
        await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary?.name.display, "openalias.org")
        XCTAssertEqual(stub.calls, 1)
    }

    func testModelAddressRowWaitsForTypingDelay() async {
        let stub = KitStub(json: "")
        let (model, _) = makeModel(stub, typingDelay: .milliseconds(200))
        model.textChanged("joe")
        XCTAssertEqual(model.phase, .pendingAddress)
        await waitUntil { model.phase == .address }
        XCTAssertEqual(model.phase, .address)
        // The same text again (the binding and onChange both report one
        // keystroke): no change.
        model.textChanged("joe")
        XCTAssertEqual(model.phase, .address)
        // Every typed change waits again.
        model.textChanged("joeb")
        XCTAssertEqual(model.phase, .pendingAddress)
        // An "@" leaves the address path: the rejection waits too.
        model.textChanged("joeb@")
        XCTAssertEqual(model.phase, .pendingRejection(.invalidName))
        // Pasted text is classified at once.
        model.submit("joe")
        XCTAssertEqual(model.phase, .address)
        model.textChanged("")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(stub.calls, 0)
    }

    func testModelRejections() async {
        let stub = KitStub(json: Fixture.answer(records: Fixture.getmoneroRecords))
        let (model, _) = makeModel(stub)
        model.textChanged("monero.one")
        XCTAssertEqual(model.phase, .pendingRejection(.reserved))
        await waitUntil { model.phase == .rejected(.reserved) }
        XCTAssertEqual(model.phase, .rejected(.reserved))
        model.submit("a.b.monero.one")
        XCTAssertEqual(model.phase, .rejected(.reserved))
        model.submit("joe@")
        XCTAssertEqual(model.phase, .rejected(.invalidName))
        // A red row on screen changes in place.
        model.textChanged("a.b.monero.one")
        XCTAssertEqual(model.phase, .rejected(.reserved))
        XCTAssertEqual(stub.calls, 0)
    }

    func testModelRetryAfterTimeout() async {
        let stub = KitStub(json: #"{"status":"timeout"}"#)
        let (model, announcements) = makeModel(stub)
        model.submit("donate@getmonero.org")
        await waitUntil { model.phase == .failed(.timeout) }
        XCTAssertEqual(model.phase, .failed(.timeout))
        XCTAssertEqual(announcements(), ["The lookup took too long"])
        model.retry()
        await waitUntil { stub.calls == 2 }
        XCTAssertEqual(stub.calls, 2)
    }

    func testModelReturnLooksUpFailedNameAgain() async {
        let stub = KitStub(json: Fixture.answer(records: []))
        let (model, _) = makeModel(stub)
        model.textChanged("donate@getmonero.org")
        await waitUntil { model.phase == .failed(.noRecord) }
        XCTAssertEqual(model.phase, .failed(.noRecord))
        XCTAssertEqual(stub.calls, 1)
        // Typing the same query name again does nothing.
        model.textChanged("donate@getmonero.org ")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.phase, .failed(.noRecord))
        XCTAssertEqual(stub.calls, 1)
        // Return looks it up again, also for a failure without Try Again.
        model.submit("donate@getmonero.org ")
        XCTAssertEqual(model.phase, .looking)
        await waitUntil { stub.calls == 2 && model.phase == .failed(.noRecord) }
        XCTAssertEqual(model.phase, .failed(.noRecord))
        XCTAssertEqual(stub.calls, 2)
    }

    func testModelWritesPinOnlyOnSuccess() {
        let (model, _) = makeModel(KitStub(json: ""))
        let summary = OpenAliasSummary(name: OpenAliasName(display: "donate@getmonero.org", query: "donate.getmonero.org"),
                                       address: Fixture.getmoneroAddress, dnssec: .valid, pin: .none)
        for phase: SendFlowPhase in [.address, .amount, .review, .sending, .error(message: "failed")] {
            XCTAssertFalse(model.recordPinIfSent(phase: phase, summary: summary, sentAddress: Fixture.getmoneroAddress))
        }
        XCTAssertFalse(model.recordPinIfSent(phase: .success(txHash: "abc"), summary: nil, sentAddress: Fixture.getmoneroAddress))
        XCTAssertEqual(pins.state(query: "donate.getmonero.org", address: Fixture.getmoneroAddress, network: .mainnet), .none)
        XCTAssertTrue(model.recordPinIfSent(phase: .success(txHash: "abc"), summary: summary, sentAddress: Fixture.getmoneroAddress))
        guard case .same = pins.state(query: "donate.getmonero.org", address: Fixture.getmoneroAddress, network: .mainnet) else {
            return XCTFail("a pin after a successful send")
        }
    }
}

// MARK: - Bridge (section 3.5)

final class DnsBridgeTests: XCTestCase {
    private let server1 = URL(string: "https://one.example/dns-query")!
    private let server2 = URL(string: "https://two.example/dns-query")!

    private func startBridge(_ transport: FakeTransport, queryCap: Int = OpenAliasResolver.Config.queryCap) async throws -> (DnsBridge, Int32) {
        let bridge = DnsBridge(transport: transport, servers: [server1, server2], queryCap: queryCap)
        let port = try await bridge.start()
        XCTAssertNotEqual(port, 0)
        return (bridge, try Loopback.connect(port: port))
    }

    private func exchange(_ fd: Int32, _ query: [UInt8]) throws -> [UInt8] {
        try Loopback.sendFrame(fd, query)
        return try XCTUnwrap(try Loopback.readFrame(fd))
    }

    func testOneQuerySendsIDZeroAndRestoresID() async throws {
        let transport = FakeTransport()
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        let query = dnsQuery(id: 0xBEEF)
        let reply = try exchange(fd, query)
        XCTAssertEqual(messageID(reply), 0xBEEF)
        XCTAssertEqual(Array(reply[12...]), Array(query[12...]))
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(messageID([UInt8](transport.calls[0].message)), 0)
        XCTAssertEqual(transport.calls[0].server, server1)
        bridge.stop()
        XCTAssertEqual(bridge.answeredCount, 1)
        XCTAssertEqual(bridge.synthesizedCount, 0)
    }

    func testPipelinedQueriesAnsweredInReverse() async throws {
        // The first query waits longest, so the answers come back in reverse.
        let transport = FakeTransport { message, url in
            let bytes = [UInt8](message)
            let first = bytes[13]  // first letter of the first label
            let wait: Duration = first == UInt8(ascii: "a") ? .milliseconds(600) : first == UInt8(ascii: "b") ? .milliseconds(300) : .zero
            try await Task.sleep(for: wait)
            return try await FakeTransport.echo(message, url)
        }
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        let names = ["a.example.com", "b.example.com", "c.example.com"]
        let ids: [UInt16] = [0x0101, 0x0202, 0x0303]
        for (name, id) in zip(names, ids) {
            try Loopback.sendFrame(fd, dnsQuery(id: id, name: name))
        }
        var replies: [[UInt8]] = []
        for _ in 0..<3 {
            replies.append(try XCTUnwrap(try Loopback.readFrame(fd)))
        }
        XCTAssertEqual(replies.map(messageID), Array(ids.reversed()))
        for reply in replies {
            let index = try XCTUnwrap(ids.firstIndex(of: messageID(reply)))
            XCTAssertEqual(Array(reply[12...]), Array(dnsQuery(id: 0, name: names[index])[12...]))
        }
        bridge.stop()
        XCTAssertEqual(bridge.answeredCount, 3)
    }

    func testFailoverAndPreference() async throws {
        let first = server1
        let transport = FakeTransport { message, url in
            if url == first { throw URLError(.cannotConnectToHost) }
            return try await FakeTransport.echo(message, url)
        }
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        XCTAssertEqual(messageID(try exchange(fd, dnsQuery(id: 1))), 1)
        XCTAssertEqual(messageID(try exchange(fd, dnsQuery(id: 2))), 2)
        XCTAssertEqual(transport.calls.map { $0.server }, [server1, server2, server2])
        bridge.stop()
        XCTAssertEqual(bridge.answeredCount, 2)
        XCTAssertEqual(bridge.synthesizedCount, 0)
    }

    func testBothServersFailGivesServfail() async throws {
        let transport = FakeTransport(handler: FakeTransport.fail)
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        let query = dnsQuery(id: 0x1234)
        let reply = try exchange(fd, query)
        XCTAssertEqual(messageID(reply), 0x1234)
        XCTAssertEqual(reply[2], 0x80 | (query[2] & 0x79))
        XCTAssertEqual(reply[3], 0x80 | (query[3] & 0x10) | 0x02)
        XCTAssertEqual(reply[3] & 0x0F, 2, "SERVFAIL")
        XCTAssertEqual(Array(reply[4..<12]), [0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(reply[12...]), Array(query[12...]), "the question is copied")
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(bridge.synthesizedCount, 1)

        // The bridge is down: the next query gets a SERVFAIL at once.
        let next = try exchange(fd, dnsQuery(id: 0x5678))
        XCTAssertEqual(messageID(next), 0x5678)
        XCTAssertEqual(next[3] & 0x0F, 2)
        XCTAssertEqual(transport.calls.count, 2)
        bridge.stop()
        XCTAssertEqual(bridge.synthesizedCount, 2)
        XCTAssertEqual(bridge.answeredCount, 0)
    }

    func testServfailWithoutQuestion() {
        let header: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0]  // a compression pointer
        let reply = DnsBridge.servfail(for: header)
        XCTAssertEqual(reply, [0xAB, 0xCD, 0x81, 0x82, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testQuery65GetsServfail() async throws {
        let transport = FakeTransport()
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        for id in 1...64 {
            XCTAssertEqual(try exchange(fd, dnsQuery(id: UInt16(id)))[3] & 0x0F, 0)
        }
        XCTAssertEqual(transport.calls.count, 64)
        let reply = try exchange(fd, dnsQuery(id: 65))
        XCTAssertEqual(messageID(reply), 65)
        XCTAssertEqual(reply[3] & 0x0F, 2)
        XCTAssertEqual(transport.calls.count, 64)
        bridge.stop()
        XCTAssertEqual(bridge.answeredCount, 64)
        XCTAssertEqual(bridge.synthesizedCount, 1)
    }

    func testShortFrameClosesConnection() async throws {
        let transport = FakeTransport()
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        try Loopback.write(fd, [0, 5, 1, 2, 3, 4, 5])
        // The bridge closes the connection: an end of stream or a reset.
        let outcome: String
        do {
            outcome = try Loopback.readFrame(fd) == nil ? "closed" : "a reply"
        } catch let error as Loopback.SocketError {
            outcome = error.code == ECONNRESET ? "closed" : "error \(error.code)"
        }
        XCTAssertEqual(outcome, "closed")
        XCTAssertEqual(transport.calls.count, 0)
    }

    func testBadRepliesAreTransportFailures() async throws {
        let bad: [DohHTTPReply] = [
            DohHTTPReply(status: 500, contentType: "application/dns-message", body: Data(dnsQuery(id: 0))),
            DohHTTPReply(status: 200, contentType: "text/html", body: Data(dnsQuery(id: 0))),
            DohHTTPReply(status: 200, contentType: "application/dns-message", body: Data([0x80, 0, 0x80, 0, 0])),
            DohHTTPReply(status: 200, contentType: "application/dns-message", body: Data(dnsQuery(id: 0))),  // no QR bit
        ]
        for reply in bad {
            XCTAssertNil(DnsBridge.dnsReply(reply))
            let first = server1
            let transport = FakeTransport { message, url in
                if url == first { return reply }
                return try await FakeTransport.echo(message, url)
            }
            let (bridge, fd) = try await startBridge(transport)
            XCTAssertEqual(messageID(try exchange(fd, dnsQuery(id: 7))), 7)
            XCTAssertEqual(transport.calls.map { $0.server }, [server1, server2])
            close(fd)
            bridge.stop()
        }
        var good = dnsQuery(id: 0)
        good[2] |= 0x80
        XCTAssertNotNil(DnsBridge.dnsReply(DohHTTPReply(status: 200, contentType: "application/dns-message; charset=binary", body: Data(good))))
    }

    // MARK: Malformed frames, FORMERR and NOTIMPL

    /// `query` with an EDNS OPT record: 4096-byte size, the DO bit on, and
    /// `options` as its data.
    private func withEdns(_ query: [UInt8], options: [UInt8] = []) -> [UInt8] {
        var message = query
        message[11] = 1  // ARCOUNT
        message += [0, 0, 41, 0x10, 0, 0, 0, 0x80, 0, UInt8(options.count >> 8), UInt8(options.count & 0xFF)]
        return message + options
    }

    /// The frame that libunbound 1.16.1 sometimes sends: the query with its
    /// ID written over its flags, so QDCOUNT reads 0.
    private func idOverFlags(_ query: [UInt8]) -> [UInt8] {
        Array(query[0..<2]) + Array(query[4...])
    }

    /// `query` (without EDNS) with another type and class.
    private func typed(_ query: [UInt8], type: UInt16, qclass: UInt16) -> [UInt8] {
        Array(query.dropLast(4)) + [UInt8(type >> 8), UInt8(type & 0xFF), UInt8(qclass >> 8), UInt8(qclass & 0xFF)]
    }

    private func replaced(_ query: [UInt8], at index: Int, with byte: UInt8) -> [UInt8] {
        var message = query
        message[index] = byte
        return message
    }

    func testWellFormedQueryCheck() {
        let query = dnsQuery(id: 3)
        let options: [UInt8] = [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 12, 0, 3, 0, 0, 0]  // a cookie, padding
        let a63 = String(repeating: "a", count: 63)
        let longestName = [a63, a63, a63, String(repeating: "b", count: 61)].joined(separator: ".")  // 255 bytes
        let edns = withEdns(query, options: options)

        // Every query that unbound sends: EDNS with options, any flags
        // other than QR and the opcode, any type and class, any case.
        let accepted: [[UInt8]] = [
            query,
            withEdns(query),
            edns,
            replaced(replaced(query, at: 2, with: 0), at: 3, with: 0),  // no flags
            replaced(replaced(query, at: 2, with: 0x07), at: 3, with: 0x70),  // AA, TC, RD, Z, AD, CD
            dnsQuery(id: 4, name: "DoNaTe.GetMonero.ORG"),
            typed(dnsQuery(id: 5, name: "_ta-4f66-9728"), type: 10, qclass: 1),  // RFC 8145
            withEdns(typed(dnsQuery(id: 6, name: "org"), type: 48, qclass: 1)),  // DNSKEY
            typed(query, type: 65535, qclass: 255),
            typed(query, type: 16, qclass: 3),  // CHAOS
            dnsQuery(id: 7, name: "."),  // the root: 17 bytes
            dnsQuery(id: 8, name: longestName),
        ]
        for message in accepted {
            XCTAssertTrue(DnsBridge.isWellFormedQuery(message), Fixture.hex(message))
        }

        var longOption = edns
        longOption[edns.count - options.count - 1] += 1  // RDLENGTH one byte too long
        let rejected: [[UInt8]] = [
            idOverFlags(query),
            idOverFlags(edns),
            replaced(query, at: 2, with: 0x81),  // QR on
            replaced(query, at: 2, with: 0x01 | 4 << 3),  // opcode NOTIFY
            replaced(query, at: 2, with: 0x01 | 5 << 3),  // opcode UPDATE
            replaced(query, at: 5, with: 0),  // no question
            replaced(query, at: 5, with: 2),  // two questions
            replaced(query, at: 7, with: 1),  // an answer record
            replaced(query, at: 9, with: 1),  // an authority record
            replaced(query, at: 11, with: 1),  // an additional record that is not there
            query + [0],  // a byte left over
            Array(query.dropLast()),  // cut short
            Array(edns.dropLast()),  // an option cut short
            longOption,
            replaced(query, at: 12, with: 64),  // a label of 64 bytes
            Array(query[0..<12]) + [0xC0, 0x0C, 0, 16, 0, 1],  // a compression pointer
            dnsQuery(id: 9, name: longestName + "b"),  // 256 bytes
            Array(query[0..<12]),  // a header only
        ]
        for message in rejected {
            XCTAssertFalse(DnsBridge.isWellFormedQuery(message), Fixture.hex(message))
        }
    }

    func testMalformedFrameGetsServfailAndNeverGoesUpstream() async throws {
        let transport = FakeTransport()
        let (bridge, fd) = try await startBridge(transport)
        defer { close(fd); bridge.stop() }

        let resend = idOverFlags(typed(dnsQuery(id: 0x4CA2, name: "_ta-4f66-9728"), type: 10, qclass: 1))
        XCTAssertEqual(resend.count, 29)
        let reply = try exchange(fd, resend)
        XCTAssertEqual(messageID(reply), 0x4CA2)
        XCTAssertEqual(reply[3] & 0x0F, 2, "SERVFAIL")
        XCTAssertEqual(transport.calls.count, 0)
        XCTAssertEqual(bridge.synthesizedCount, 1)

        // Only that query fails: the next query goes out.
        let next = try exchange(fd, withEdns(dnsQuery(id: 9, name: "org")))
        XCTAssertEqual(messageID(next), 9)
        XCTAssertEqual(next[3] & 0x0F, 0)
        XCTAssertEqual(transport.calls.count, 1)
        bridge.stop()
        XCTAssertEqual(bridge.answeredCount, 1)
        XCTAssertEqual(bridge.synthesizedCount, 1)
    }

    func testFormerrAndNotimplAreNeverPassedOn() async throws {
        for rcode: UInt8 in [1, 4] {
            let refuse: FakeTransport.Handler = { message, _ in
                var bytes = [UInt8](message)
                bytes[2] |= 0x80
                bytes[3] = (bytes[3] & 0xF0) | rcode
                return DohHTTPReply(status: 200, contentType: "application/dns-message", body: Data(bytes))
            }
            let refused = try await refuse(Data(dnsQuery(id: 0)), server1)
            XCTAssertTrue(DnsBridge.isRefusal(try XCTUnwrap(DnsBridge.dnsReply(refused))), "rcode \(rcode)")

            // One server: the next server answers.
            let first = server1
            let oneBad = FakeTransport { message, url in
                if url == first { return try await refuse(message, url) }
                return try await FakeTransport.echo(message, url)
            }
            let (bridge, fd) = try await startBridge(oneBad)
            let answer = try exchange(fd, withEdns(dnsQuery(id: 10, name: "org")))
            XCTAssertEqual(messageID(answer), 10)
            XCTAssertEqual(answer[3] & 0x0F, 0)
            XCTAssertEqual(oneBad.calls.map { $0.server }, [server1, server2])
            close(fd)
            bridge.stop()
            XCTAssertEqual(bridge.answeredCount, 1)
            XCTAssertEqual(bridge.synthesizedCount, 0)

            // Every server refuses "org": a SERVFAIL made by the bridge.
            let allBad = FakeTransport { message, url in
                if [UInt8](message)[13] == UInt8(ascii: "o") { return try await refuse(message, url) }
                return try await FakeTransport.echo(message, url)
            }
            let (bridge2, fd2) = try await startBridge(allBad)
            let servfail = try exchange(fd2, withEdns(dnsQuery(id: 11, name: "org")))
            XCTAssertEqual(messageID(servfail), 11)
            XCTAssertEqual(servfail[3] & 0x0F, 2)
            XCTAssertEqual(allBad.calls.count, 2)
            XCTAssertEqual(bridge2.synthesizedCount, 1)

            // A refusal is not a transport failure: the bridge is not down,
            // so the next query still goes upstream and gets its answer.
            let next = try exchange(fd2, withEdns(dnsQuery(id: 12, name: "net")))
            XCTAssertEqual(messageID(next), 12)
            XCTAssertEqual(next[3] & 0x0F, 0)
            XCTAssertEqual(allBad.calls.map { $0.server }, [server1, server2, server1])
            close(fd2)
            bridge2.stop()
            XCTAssertEqual(bridge2.answeredCount, 1)
            XCTAssertEqual(bridge2.synthesizedCount, 1)
        }

        // Other rcodes go on as the server sent them.
        for rcode: UInt8 in [0, 2, 3, 5] {
            var bytes = dnsQuery(id: 0)
            bytes[2] |= 0x80
            bytes[3] = (bytes[3] & 0xF0) | rcode
            XCTAssertEqual(DnsBridge.dnsReply(DohHTTPReply(status: 200, contentType: "application/dns-message", body: Data(bytes))), bytes)
            XCTAssertFalse(DnsBridge.isRefusal(bytes), "rcode \(rcode)")
        }
    }

    func testStoppedBridgeRefusesConnections() async throws {
        let bridge = DnsBridge(transport: FakeTransport(), servers: [server1, server2])
        let port = try await bridge.start()
        close(try Loopback.connect(port: port))
        bridge.stop()
        var refused = false
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            do {
                close(try Loopback.connect(port: port))
                try await Task.sleep(for: .milliseconds(50))
            } catch let error as Loopback.SocketError {
                XCTAssertEqual(error.code, ECONNREFUSED)
                refused = true
                break
            }
        }
        XCTAssertTrue(refused)
    }

    // MARK: Listener start

    func testStartResultForListenerStates() {
        XCTAssertNil(DnsBridge.startResult(for: .setup, port: nil))
        XCTAssertEqual(try DnsBridge.startResult(for: .ready, port: 5300)?.get(), 5300)
        XCTAssertThrowsError(try DnsBridge.startResult(for: .ready, port: 0)?.get())
        // A listener that waits for a network fails at once.
        XCTAssertThrowsError(try DnsBridge.startResult(for: .waiting(.posix(.ENETDOWN)), port: nil)?.get())
        XCTAssertThrowsError(try DnsBridge.startResult(for: .failed(.posix(.EADDRINUSE)), port: nil)?.get())
        XCTAssertThrowsError(try DnsBridge.startResult(for: .cancelled, port: nil)?.get()) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }

    /// A bridge whose listener never reports a state: its queue is held.
    /// The caller resumes the queue at the end of the test.
    private func heldBridge() -> (DnsBridge, DispatchQueue) {
        let queue = DispatchQueue(label: "test.bridge.held")
        queue.suspend()
        return (DnsBridge(transport: FakeTransport(), servers: [server1, server2], listenerQueue: queue), queue)
    }

    /// A stopped bridge refuses a new start at once.
    private func assertStopped(_ bridge: DnsBridge, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await bridge.start(timeout: 60)
            XCTFail("a stopped bridge started", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    func testStartEndsAtDeadline() async {
        let (bridge, queue) = heldBridge()
        defer { queue.resume() }
        let started = Date()
        do {
            _ = try await bridge.start(timeout: 0.3)
            XCTFail("a listener without a state")
        } catch {
            XCTAssertTrue(error is DnsBridge.StartTimeout, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        await assertStopped(bridge)
    }

    func testCancelEndsStart() async {
        let (bridge, queue) = heldBridge()
        defer { queue.resume() }
        let task = Task { try await bridge.start(timeout: 60) }
        try? await Task.sleep(for: .milliseconds(200))
        let cancelled = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 3)
        XCTAssertThrowsError(try result.get()) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        await assertStopped(bridge)
    }

    // MARK: Tor configuration

    func testSessionConfigurationWithProxy() throws {
        let proxy = try XCTUnwrap(OpenAliasResolver.parseProxy("localhost:9050"))
        XCTAssertEqual(proxy, OpenAliasResolver.Proxy(host: "localhost", port: 9050))
        let configuration = OpenAliasResolver.sessionConfiguration(proxy: proxy, timeout: OpenAliasResolver.Config.dohTimeoutTor)
        XCTAssertEqual(configuration.proxyConfigurations.count, 1)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        let direct = OpenAliasResolver.sessionConfiguration(proxy: nil, timeout: OpenAliasResolver.Config.dohTimeoutDirect)
        XCTAssertTrue(direct.proxyConfigurations.isEmpty)
        XCTAssertEqual(direct.timeoutIntervalForRequest, 5)
    }

    private struct SocksConnect: Equatable, Sendable {
        let addressType: UInt8
        let host: String
        let port: UInt16
    }

    /// A SOCKS5 proxy that reads one CONNECT request and closes. Nil when
    /// none arrives in 5 s.
    private static func readSocksConnect(listening fd: Int32) -> SocksConnect? {
        var incoming = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 5000) == 1 else { return nil }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // The greeting: version 5 and the methods. The reply: no authentication.
        guard let greeting = try? Loopback.read(client, count: 2), greeting[0] == 5,
              (try? Loopback.read(client, count: Int(greeting[1]))) != nil,
              (try? Loopback.write(client, [5, 0])) != nil,
              // The request: version, CONNECT, reserved, address type.
              let request = try? Loopback.read(client, count: 4), request[1] == 1 else { return nil }
        var host = ""
        switch request[3] {
        case 3:
            guard let length = try? Loopback.read(client, count: 1),
                  let name = try? Loopback.read(client, count: Int(length[0])) else { return nil }
            host = String(decoding: name, as: UTF8.self)
        case 4:
            guard (try? Loopback.read(client, count: 16)) != nil else { return nil }
        default:
            guard (try? Loopback.read(client, count: 4)) != nil else { return nil }
        }
        guard let port = try? Loopback.read(client, count: 2) else { return nil }
        return SocksConnect(addressType: request[3], host: host, port: UInt16(port[0]) << 8 | UInt16(port[1]))
    }

    func testSocksConnectCarriesDohHostName() async throws {
        let (fd, port) = try Loopback.bind(listen: true)
        let proxyServer = Task.detached { () -> SocksConnect? in
            defer { close(fd) }
            return Self.readSocksConnect(listening: fd)
        }
        // The IPv4 loopback as text, built at run time.
        let proxy = OpenAliasResolver.Proxy(host: "\(IPv4Address.loopback)", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)))
        let transport = URLSessionDohTransport(configuration: OpenAliasResolver.sessionConfiguration(
            proxy: proxy, timeout: OpenAliasResolver.Config.dohTimeoutDirect))
        defer { transport.invalidate() }
        do {
            _ = try await transport.post(Data(dnsQuery(id: 0)), to: OpenAliasResolver.Config.servers[0])
            XCTFail("the fake proxy never connects")
        } catch {
            // Expected: the fake proxy closes after the request.
        }
        let connect = await proxyServer.value
        // Address type 3, a domain name: the proxy resolves the host name.
        XCTAssertEqual(connect, SocksConnect(addressType: 3, host: "dns.quad9.net", port: 443))
    }

    func testParseProxy() {
        XCTAssertEqual(OpenAliasResolver.parseProxy("tor.example:9150"), OpenAliasResolver.Proxy(host: "tor.example", port: 9150))
        for bad in ["not-a-proxy", "localhost:", ":9050", "localhost:0", "localhost:70000", "localhost:90x0", ""] {
            XCTAssertNil(OpenAliasResolver.parseProxy(bad), bad)
        }
    }

    func testBadProxyGivesTorErrorWithoutTraffic() async {
        let transport = FakeTransport()
        let kitCalls = LockedCounter()
        var resolver = OpenAliasResolver()
        resolver.proxyAddress = { "not-a-proxy" }
        resolver.makeTransport = { _ in transport }
        resolver.kitLookup = { _, _, _ in
            kitCalls.increment()
            return ""
        }
        let result = await resolver.resolve(OpenAliasName(display: "donate@getmonero.org", query: "donate.getmonero.org")) { _ in .valid }
        XCTAssertEqual(result, .failure(.tor))
        XCTAssertEqual(transport.calls.count, 0)
        XCTAssertEqual(kitCalls.value, 0)
    }

    func testTorOnPassesTorTimeoutToKit() async {
        let timeouts = LockedCounter()
        var resolver = OpenAliasResolver()
        resolver.proxyAddress = { "localhost:9050" }
        resolver.makeTransport = { configuration in
            XCTAssertEqual(configuration.proxyConfigurations.count, 1)
            return FakeTransport()
        }
        resolver.kitLookup = { _, _, timeoutMs in
            timeouts.set(Int(timeoutMs))
            return #"{"status":"error","error":"x"}"#
        }
        let result = await resolver.resolve(OpenAliasName(display: "openalias.org", query: "openalias.org")) { _ in .valid }
        XCTAssertEqual(result, .failure(.tor))
        XCTAssertEqual(timeouts.value, 30_000)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func set(_ newValue: Int) { lock.withLock { count = newValue } }
}

// MARK: - Kit lookup (section 8.2)

final class OpenAliasKitLookupTests: XCTestCase {
    private func lookup(_ name: String, port: UInt16, timeoutMs: Int32) -> [String: Any] {
        let json = Kit.lookupOpenAliasTXT(name: name, forwarderPort: port, timeoutMs: timeoutMs)
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return object as? [String: Any] ?? [:]
    }

    func testBadArguments() throws {
        let (fd, port) = try Loopback.bind(listen: false)
        close(fd)
        XCTAssertEqual(lookup("", port: port, timeoutMs: 5000)["status"] as? String, "error")
        XCTAssertEqual(lookup("donate.getmonero.org", port: 0, timeoutMs: 5000)["status"] as? String, "error")
        XCTAssertEqual(lookup("donate.getmonero.org", port: port, timeoutMs: 500)["status"] as? String, "error")
    }

    func testClosedPortGivesServfailFast() throws {
        let (fd, port) = try Loopback.bind(listen: false)
        close(fd)
        let start = Date()
        let answer = lookup("donate.getmonero.org", port: port, timeoutMs: 5000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(answer["status"] as? String, "ok", "\(answer)")
        XCTAssertEqual(answer["rcode"] as? Int, 2)
        XCTAssertLessThan(elapsed, 1)
    }

    func testSilentListenerTimesOut() throws {
        let (fd, port) = try Loopback.bind(listen: true)
        defer { close(fd) }
        let start = Date()
        let answer = lookup("donate.getmonero.org", port: port, timeoutMs: 1000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(answer["status"] as? String, "timeout", "\(answer)")
        XCTAssertLessThan(elapsed, 2)
    }

    /// A compile and link check only. The wallet2 resolver is never called:
    /// its first call probes updates.moneropulse.org over port 53.
    func testWallet2ResolverLinks() {
        let resolver: (String) -> (address: String, dnssecValid: Bool)? = Kit.resolveOpenAliasWithWallet2
        XCTAssertNotNil(resolver as Any?)
    }
}

// MARK: - Live loop (network)

/// Live network: many real lookups of one name, to count the outcomes. Runs
/// only when the test process has OPENALIAS_LIVE=1, for example with
/// `TEST_RUNNER_OPENALIAS_LIVE=1 xcodebuild test ...`. OPENALIAS_COUNT sets
/// the count and OPENALIAS_PAUSE_MS the pause after each lookup.
final class OpenAliasLiveLoopTests: XCTestCase {
    func testLookUpManyTimes() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OPENALIAS_LIVE"] == "1", "The live loop runs only with OPENALIAS_LIVE=1.")
        let count = environment["OPENALIAS_COUNT"].flatMap { Int($0) } ?? 40
        let pause = environment["OPENALIAS_PAUSE_MS"].flatMap { Int($0) } ?? 500
        let name = OpenAliasName(display: "donate@getmonero.org", query: "donate.getmonero.org")
        let resolver = OpenAliasResolver()
        var tally: [String: Int] = [:]
        for run in 1...max(count, 1) {
            let started = Date()
            let outcome = await resolver.resolve(name) { _ in .valid }
            let label: String
            switch outcome {
            case .success(let found): label = "resolved, DNSSEC \(found.dnssec)"
            case .failure(let failure): label = "failed, \(failure)"
            }
            tally[label, default: 0] += 1
            print("[OpenAliasLoop] \(run)/\(count): \(label) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            try await Task.sleep(for: .milliseconds(pause))
        }
        print("[OpenAliasLoop] tally over \(count): \(tally.sorted(by: <))")
    }
}
