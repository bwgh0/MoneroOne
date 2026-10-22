import XCTest

@testable import MoneroOne

@MainActor
final class UsernameResolutionTests: XCTestCase {
  private var fixture: [String: Any] {
    let url = Bundle(for: Self.self).url(forResource: "username-resolution", withExtension: "json")!
    return (try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])[
      "request"] as! [String: Any]
  }
  private func decode(_ input: String) -> Data {
    let value = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))!
  }
  private func resolver(store: ReceiptMemory, status: Int = 200, tamper: Bool = false)
    -> UsernameResolver
  {
    let value = fixture
    let snapshot = value["snapshot"] as! [String: Any]
    let records = value["records"] as! [String]
    let buckets = decode(snapshot["bucket"] as! String) + decode(snapshot["signature"] as! String)
    let genesis = decode(value["genesis_epoch"] as! String)
    let rules = Data((value["rules"] as! String).utf8)
    var manifest: [String: Any] = [
      "encoding": snapshot["epoch"]!, "checkpoint": snapshot["checkpoint"]!,
      "published_at": snapshot["published_at"]!,
      "publication_signature": snapshot["publication_signature"]!,
    ]
    if tamper { manifest["published_at"] = 1_000_001 }
    let manifestData = try! JSONSerialization.data(withJSONObject: manifest)
    let head = try! JSONSerialization.data(withJSONObject: [
      "owner": "forged API address", "records": records.map { ["record": $0] },
    ])
    ResolutionURLProtocol.handler = { request in
      let path = request.url!.path
      if path == "/v1/handles/alice" { return (status, head) }
      if path == "/v1/rules" { return (200, rules) }
      if path == "/snapshots/latest" { return (200, Data("1".utf8)) }
      if path == "/epochs/1/manifest.json" { return (200, manifestData) }
      if path == "/epochs/0/epoch" { return (200, genesis) }
      if path.hasPrefix("/snapshots/1/buckets/") { return (200, buckets) }
      XCTFail("Unexpected path \(path)")
      throw URLError(.badURL)
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ResolutionURLProtocol.self]
    return UsernameResolver(
      configuration: .init(
        registry: .init(
          url: URL(string: "https://registry.example")!,
          registrarKey: value["registrar_key"] as! String, rulesHash: value["rules_hash"] as! String
        ),
        mirror: URL(string: "https://mirror.example")!,
        genesisRoot: value["genesis_epoch_root"] as! String),
      network: "mainnet", session: URLSession(configuration: sessionConfiguration), store: store,
      now: { Date(timeIntervalSince1970: 1_000_100) }, ownedGenesis: { _, _ in nil })
  }
  private let recipient = OpenAliasName(display: "@alice", query: "alice.monero.one")
  override func tearDown() {
    ResolutionURLProtocol.handler = nil
    super.tearDown()
  }

  func testPaymentAddressComesFromSignaturesAndPinsTheRoot() async throws {
    let store = ReceiptMemory()
    let client = resolver(store: store)
    let result = try await client.resolve(recipient)
    XCTAssertEqual(result.usernameTrust, .published)
    XCTAssertNotEqual(result.address, "forged API address")
    XCTAssertNotNil(store.receipts["alice"])
    XCTAssertEqual((store.receipts["alice"]?["recipients"] as? [String])?.count, 1)
  }
  func testDottedNameIsNotAUsername() async throws {
    let store = ReceiptMemory()
    let client = resolver(store: store)
    ResolutionURLProtocol.handler = { request in
      XCTFail("A dotted name must not reach the registry: \(request.url?.path ?? "")")
      throw URLError(.badURL)
    }
    do {
      _ = try await client.resolve(
        OpenAliasName(display: "@work.alice", query: "work.alice.monero.one"))
      XCTFail("A dotted name resolved")
    } catch {
      XCTAssertEqual(error as? OpenAliasFailure, .usernameVerification)
    }
    XCTAssertTrue(store.receipts.isEmpty)
  }
  func testNoAddressEscapesWhenReceiptCannotBeSaved() async throws {
    let store = ReceiptMemory()
    store.fail = true
    do {
      _ = try await resolver(store: store).resolve(recipient)
      XCTFail("Failed storage must stop Send")
    } catch { XCTAssertTrue(store.receipts.isEmpty) }
  }
  func testHoldAndAlteredSnapshotStopResolutionWithoutSaving() async throws {
    for held in [true, false] {
      let store = ReceiptMemory()
      do {
        _ = try await resolver(store: store, status: held ? 451 : 200, tamper: !held).resolve(recipient)
        XCTFail("Untrusted resolution escaped")
      } catch { XCTAssertTrue(store.receipts.isEmpty) }
    }
  }

  // MARK: - Recheck before broadcast

  private let reviewed = "4" + String(repeating: "A", count: 94)
  private func recheck(
    _ trust: UsernameTrust?, address: String? = nil, amount: String = "0.05",
    all: Bool = false
  ) -> String? {
    UsernameSendRecheck.failure(
      reviewedAddress: reviewed, amount: Decimal(string: amount), isSendingAll: all,
      result: .success(
        OpenAliasResult(
          address: address ?? reviewed, recipientName: nil, dnssec: .off, usernameTrust: trust)))
  }
  func testRecheckBlocksOnlyWhenTheAddressChanged() {
    let changed = "The username changed since your review. Look it up again before sending."
    XCTAssertEqual(recheck(.published, address: "8" + String(repeating: "B", count: 94)), changed)
    // A trust change alone sends.
    for trust in [UsernameTrust.published, .pending, .stale, .expired] {
      XCTAssertNil(recheck(trust), "\(trust)")
    }
    XCTAssertEqual(
      UsernameSendRecheck.failure(
        reviewedAddress: reviewed, amount: 1, isSendingAll: false,
        result: .failure(.usernameVerification)),
      OpenAliasFailure.usernameVerification.message)
  }
  func testRecheckAppliesTheLimitOfTheNewTrust() {
    let stale = "Username records are out of date. The payment limit is 0.1 XMR."
    // Published at review, stale at broadcast: the limit applies.
    XCTAssertEqual(recheck(.stale, amount: "0.5"), stale)
    XCTAssertEqual(recheck(.expired, amount: "0.11"), stale)
    XCTAssertNil(recheck(.stale, amount: "0.1"))
    XCTAssertEqual(recheck(.stale, amount: "0.01", all: true), stale)
    // Published at broadcast: no limit.
    XCTAssertNil(recheck(.published, amount: "5"))
    XCTAssertNil(recheck(.published, amount: "5", all: true))
  }
  func testPendingGetsTheLimitWithItsOwnMessage() {
    let pending = "This username is not in the public log yet. The payment limit is 0.1 XMR."
    let stale = "Username records are out of date. The payment limit is 0.1 XMR."
    XCTAssertNil(UsernameTrust.published.amountLimit)
    XCTAssertNil(UsernameTrust.published.limitMessage)
    for trust in [UsernameTrust.pending, .stale, .expired] {
      XCTAssertEqual(trust.amountLimit, Decimal(string: "0.1"), "\(trust)")
    }
    XCTAssertEqual(UsernameTrust.pending.limitMessage, pending)
    XCTAssertEqual(UsernameTrust.stale.limitMessage, stale)
    XCTAssertEqual(UsernameTrust.expired.limitMessage, stale)
    // Published at review, pending at broadcast: the pending limit applies.
    XCTAssertEqual(recheck(.pending, amount: "0.5"), pending)
    XCTAssertEqual(recheck(.pending, amount: "0.01", all: true), pending)
    XCTAssertNil(recheck(.pending, amount: "0.1"))
  }
}

private final class ReceiptMemory: UsernameResolutionPersistence {
  var receipts: [String: [String: Any]] = [:]
  var fail = false
  func read(_ name: String) throws -> [String: Any]? { receipts[name] }
  func write(_ value: [String: Any], name: String) throws {
    if fail { throw UsernameFailure.storage }
    receipts[name] = value
  }
}
private final class ResolutionURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler!(request)
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
