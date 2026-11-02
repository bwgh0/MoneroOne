import XCTest

@testable import MoneroOne

/// Retire, holds and the next free claim. Every key here is a PUBLIC TEST
/// key from the oah vectors or the registry's e2e harness; no private key
/// is in this file.
@MainActor
final class UsernameRetireTests: XCTestCase {
  // oah vectors/records.json "alice-r5-tombstone" (the last record of
  // chains.json "rust-alice-full"), signed by the oah test signer and the
  // oah test registrar key.
  private enum Vector {
    static let handle = "alice"
    static let genesis = "29d0d6dcd5dd31533dbb692300024144b8045b7898aec31427ca48e7c7eaf607"
    static let owner =
      "858fwkeUyVCX5oAPhj7UT61SKx5KeTJYtPDHaHVj36eUE6ryjp9BWcueXomannj372HvoGVPJhxcqErDzgFfa3iRQkKy1pG"
    static let headSeq: UInt32 = 4
    static let prev = "247d4c3dc48ffa885bfd40b9b4c1a906de318dc863042240694a9167c16c2d69"
    static let unsigned =
      "4f4148310405616c69636500000005247d4c3dc48ffa885bfd40b9b4c1a906de318dc863042240694a9167c16c2d69"
    static let recordHash = "73af89cf03e112cd21a3a564b6e4647362ebec8ddc261a8931b744730985c0a0"
    static let message = "oah/tombstone/v1:73af89cf03e112cd21a3a564b6e4647362ebec8ddc261a8931b744730985c0a0"
    static let ownerSignature =
      "SigV2DdB9mU19jey3EBHevPvW3Ed6ZxXzsbkrnSh1Njr58uD5U3NwmLMQneL4asEhmuwJYPWUPgbx8rxb37RLLqL8CzGR"
    static let record =
      "4f4148310405616c69636500000005247d4c3dc48ffa885bfd40b9b4c1a906de318dc863042240694a9167c16c2d69"
      + "4b78e30aa1f7b2a20d50c6de8036349dd7cdcce6c306e6639996cde5b83dd404a1aae89d0b8e5081156d3e5202cac430b034005548c952ea266143a9738c750a"
      + "0f065e50a7e932b2f1d37ad3893994e96a653464f618c8caa84a6de6d405f292009c5c1438fbc2e48f1a411994c979d24ed14c3163d224b9056f6f653c9d9802"
    static let registrarKey = "49bdfa652580e7d75672be3d708a8a0f9c3e424a3ec08818406fb3925ebb017e"
  }

  // The registry e2e harness log key (crates/e2e/tests/common). Its hold
  // notices are `notice_text("monero.one", "alice", <reason>, START)`, as in
  // crates/e2e/tests/valve.rs, signed with Ed25519.
  private enum Hold {
    static let key = "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
    static let heldAt: TimeInterval = 1_790_000_000
    static let signatures: [UsernameHoldReason: String] = [
      .order: "uHjjTJ_iIgNcuTxutbFsu4or0Dtx63clrdHhlMYZbTZGnRo_hJz2ZcvkQ1fMuwE9X8gBagJKLjF-c3tRtjfXAg",
      .notice: "GEGPqFRotntJHhibqBHdtjKqJYYBXFK8wztVZzjVMR4vWFo3uvaomNwx5i5p7HwlXOpVVwBEkjz195OrhCQYBg",
      .sanctions: "yC2kUxNKfoz_30-vGW_ua0BkBzvJ61aBYZELjNRhtyPKhibi2JlT5tbCbafNTGRWR6hCQJHb9Nwy4It_nUFSCQ",
      .terms: "Bz9CTXRJgvDSnHxaiXjfdwiRO8yfYft0vRY7aX3j1UlbZWRUj1geVrHvaXbjJZwbbGChCpDGr2IJl4K0UEyLBg",
    ]
    /// The registrar's countersignature of the vector's tombstone, by this key.
    static let countersignature =
      "5129ec30576fbd2cd69f3680fafa5daed05b8b167748c3ce5e2ef59ce18972ac3f480fc3eb999f5c3151137ede6b984e7c43c20d253fbb2cbfb76de407d93f05"
    static func notice(_ reason: String, handle: String = "alice", zone: String = "monero.one") -> String {
      "oah-registry/hold/v1\nzone \(zone)\nhandle \(handle)\nreason \(reason)\nheld_at 1790000000\n"
    }
    /// The vector's tombstone as this registrar returns it.
    static var record: String { String(Vector.record.dropLast(128)) + countersignature }
  }

  private static func data(hex: String) -> Data {
    var bytes = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return bytes
  }
  private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  /// The `451 name.held` body of the registry (valve.rs `held_error`).
  private func heldBody(
    _ reason: UsernameHoldReason, notice: String? = nil, signature: String? = nil,
    head: [String: Any]? = ["seq": 4, "record_hash": Vector.prev]
  ) -> [String: Any] {
    var hold: [String: Any] = [
      "handle": "alice", "reason": reason.rawValue, "held_at": 1_790_000_000,
      "notice": notice ?? Hold.notice(reason.rawValue),
      "signature": signature ?? Hold.signatures[reason]!,
    ]
    hold["head"] = head ?? NSNull()
    return [
      "error": ["code": "name.held", "message": "This name is on hold.", "reason": reason.rawValue],
      "hold": hold,
    ]
  }
  private var binding: UsernameBinding {
    UsernameBinding(
      walletKey: "wallet-A", network: "mainnet", handle: Vector.handle, displayHandle: "Alice",
      subaddress: Vector.owner, genesisHash: Vector.genesis, record: "record", claimedAt: Date())
  }
  /// The registry's lookup of a live alice at the vector's head.
  private var live: [String: Any] {
    [
      "handle": "alice", "genesis_hash": Vector.genesis, "owner": Vector.owner, "tombstoned": false,
      "head": ["seq": 4, "record_hash": Vector.prev], "records": [],
    ]
  }
  private func client(registrarKey: String = Vector.registrarKey) -> UsernameRegistry {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RetireURLProtocol.self]
    return UsernameRegistry(
      configuration: UsernameConfiguration(
        url: URL(string: "http://localhost:8787")!, registrarKey: registrarKey,
        rulesHash: String(repeating: "c", count: 64), termsVersion: "test-terms-v1"),
      session: URLSession(configuration: config))
  }
  /// A store that holds alice for wallet-A, claimed on this phone now.
  private func store() throws -> UsernameStore {
    let store = UsernameStore(persistence: RetireMemory())
    try store.accept(binding)
    return store
  }
  private var paths: [String] = []
  /// Serves `lookup` for the handle, and `post` for the retire.
  private func serve(lookup: (Int, Any), post: (Int, Any)? = nil, check: (([String: Any]) -> Void)? = nil) {
    paths = []
    RetireURLProtocol.handler = { [weak self] request in
      let method = request.httpMethod ?? "GET"
      let path = request.url?.path ?? ""
      self?.paths.append(method + " " + path)
      switch (method, path) {
      case ("GET", "/v1/handles/alice"): return lookup
      case ("POST", "/v1/handles/alice/records"):
        guard let post else { XCTFail("No retire may be posted"); throw URLError(.badURL) }
        check?(RetireURLProtocol.body(request))
        return post
      default:
        XCTFail("Unexpected \(method) \(path)")
        throw URLError(.badURL)
      }
    }
  }
  private func retire(
    _ client: UsernameRegistry, _ store: UsernameStore, current: @escaping () -> Bool = { true },
    sign: ((String, String) throws -> String)? = nil
  ) async throws {
    try await client.retire(
      binding(in: store), store: store,
      sign: sign ?? { message, address in
        XCTAssertEqual(message, Vector.message)
        XCTAssertEqual(address, Vector.owner)
        return Vector.ownerSignature
      }, isCurrentWallet: current)
  }
  private func binding(in store: UsernameStore) -> UsernameBinding {
    store.binding(walletKey: "wallet-A", network: "mainnet")!
  }
  private let noSignature: (String, String) throws -> String = { _, _ in
    XCTFail("Nothing may be signed")
    throw UsernameFailure.verification
  }
  override func tearDown() {
    RetireURLProtocol.handler = nil
    super.tearDown()
  }

  // MARK: - The tombstone

  func testTombstoneBytesHashAndMessageMatchTheOahVector() throws {
    let unsigned = try XCTUnwrap(
      UsernameTombstone.unsigned(handle: Vector.handle, seq: Vector.headSeq + 1, prev: Vector.prev))
    XCTAssertEqual(Self.hex(unsigned), Vector.unsigned)
    XCTAssertEqual(UsernameTombstone.recordHash(unsigned), Vector.recordHash)
    XCTAssertEqual(UsernameTombstone.signingMessage(unsigned), Vector.message)
    // seq is big-endian: 0x01020304 gives those four bytes after the handle.
    let wide = try XCTUnwrap(UsernameTombstone.unsigned(handle: "alice", seq: 0x0102_0304, prev: Vector.prev))
    XCTAssertEqual(Self.hex(wide.subdata(in: 11..<15)), "01020304")
    // Values the registry would refuse are never signed.
    XCTAssertNil(UsernameTombstone.unsigned(handle: "alice", seq: 0, prev: Vector.prev))
    XCTAssertNil(UsernameTombstone.unsigned(handle: "alice", seq: 5, prev: Vector.prev.uppercased()))
    XCTAssertNil(UsernameTombstone.unsigned(handle: "alice", seq: 5, prev: String(Vector.prev.dropLast(2))))
    for bad in ["Alice", "ab", "abcdefghijklmnop", "a__b", "1abc", "al-ce", "alicé", ""] {
      XCTAssertNil(UsernameTombstone.unsigned(handle: bad, seq: 5, prev: Vector.prev), bad)
    }
    // A name that the blocked list holds today can still retire.
    XCTAssertNotNil(UsernameTombstone.unsigned(handle: "support", seq: 1, prev: Vector.prev))
  }
  func testTheRegistrarCountersignatureIsChecked() throws {
    let unsigned = Self.data(hex: Vector.unsigned)
    let record = Self.data(hex: Vector.record)
    XCTAssertTrue(UsernameTombstone.isCountersigned(record, unsigned: unsigned, registrarKey: Vector.registrarKey))
    XCTAssertFalse(UsernameTombstone.isCountersigned(record, unsigned: unsigned, registrarKey: Hold.key))
    var tampered = record
    tampered[tampered.count - 1] ^= 1
    XCTAssertFalse(UsernameTombstone.isCountersigned(tampered, unsigned: unsigned, registrarKey: Vector.registrarKey))
    let other = try XCTUnwrap(UsernameTombstone.unsigned(handle: "alice", seq: 6, prev: Vector.recordHash))
    XCTAssertFalse(UsernameTombstone.isCountersigned(record, unsigned: other, registrarKey: Vector.registrarKey))
    XCTAssertFalse(
      UsernameTombstone.isCountersigned(record.dropLast(1), unsigned: unsigned, registrarKey: Vector.registrarKey))
    XCTAssertTrue(
      UsernameTombstone.isCountersigned(Self.data(hex: Hold.record), unsigned: unsigned, registrarKey: Hold.key))
  }
  func testBase64URLDecodeIsStrict() {
    XCTAssertEqual(UsernameDevice.base64URLDecode("-_8"), Data([0xfb, 0xff]))
    XCTAssertEqual(UsernameDevice.base64URLDecode(""), Data())
    for bad in ["-_8=", "+/8", "AB", "A", "a b", "QUJD\n"] {
      XCTAssertNil(UsernameDevice.base64URLDecode(bad), bad)
    }
  }

  // MARK: - The hold notice

  func testEachSignedHoldNoticeGivesItsReasonDateAndHead() throws {
    for reason in UsernameHoldReason.allCases {
      let hold = try XCTUnwrap(
        UsernameHold.parse(heldBody(reason), handle: "alice", registrarKey: Hold.key), reason.rawValue)
      XCTAssertEqual(hold.reason, reason)
      XCTAssertEqual(hold.handle, "alice")
      XCTAssertEqual(hold.heldAt, Date(timeIntervalSince1970: Hold.heldAt))
      XCTAssertEqual(hold.head, UsernameHead(seq: 4, recordHash: Vector.prev))
      XCTAssertEqual(hold.allowsRetire, reason == .notice || reason == .terms, reason.rawValue)
    }
    // A hold with no head shows its reason and offers no retire.
    let headless = try XCTUnwrap(UsernameHold.parse(heldBody(.notice, head: nil), handle: "alice", registrarKey: Hold.key))
    XCTAssertNil(headless.head)
    XCTAssertFalse(headless.allowsRetire)
    // The reason comes from the signed notice, not the unsigned fields.
    var mixed = heldBody(.order)
    mixed["error"] = ["code": "name.held", "reason": "notice"]
    var fields = mixed["hold"] as! [String: Any]
    fields["reason"] = "notice"
    mixed["hold"] = fields
    XCTAssertEqual(UsernameHold.parse(mixed, handle: "alice", registrarKey: Hold.key)?.reason, .order)
  }
  func testAHoldNoticeThatFailsACheckGivesNoHold() {
    let order = Hold.signatures[.order]!
    let rows: [(String, [String: Any], String, String)] = [
      ("another registrar key", heldBody(.order), "alice", Vector.registrarKey),
      ("the reason changed", heldBody(.notice, notice: Hold.notice("notice"), signature: order), "alice", Hold.key),
      ("another notice's signature", heldBody(.order, signature: Hold.signatures[.terms]), "alice", Hold.key),
      ("another name asked", heldBody(.order), "bobby", Hold.key),
      ("another name in the notice", heldBody(.order, notice: Hold.notice("order", handle: "bobby")), "bobby", Hold.key),
      ("another zone", heldBody(.order, notice: Hold.notice("order", zone: "example.com")), "alice", Hold.key),
      ("an unknown reason", heldBody(.order, notice: Hold.notice("legal")), "alice", Hold.key),
      ("a padded signature", heldBody(.order, signature: order + "=="), "alice", Hold.key),
      ("a standard base64 signature", heldBody(.order, signature: order.replacingOccurrences(of: "-", with: "+")), "alice", Hold.key),
      ("a short signature", heldBody(.order, signature: String(order.dropLast(4))), "alice", Hold.key),
      ("not name.held", { var b = heldBody(.order); b["error"] = ["code": "write.refused"]; return b }(), "alice", Hold.key),
      ("no hold object", ["error": ["code": "name.held"]], "alice", Hold.key),
    ]
    for (name, body, handle, key) in rows {
      XCTAssertNil(UsernameHold.parse(body, handle: handle, registrarKey: key), name)
    }
  }
  func testHeadNeedsAWholeSeqAndALowercaseHash() {
    XCTAssertEqual(UsernameHead(json: ["seq": 0, "record_hash": Vector.prev])?.seq, 0)
    XCTAssertEqual(UsernameHead(json: ["seq": 4_294_967_295, "record_hash": Vector.prev])?.seq, UInt32.max)
    for bad: Any in [
      ["seq": -1, "record_hash": Vector.prev], ["seq": 4_294_967_296, "record_hash": Vector.prev],
      ["seq": 1.5, "record_hash": Vector.prev], ["seq": true, "record_hash": Vector.prev],
      ["seq": "4", "record_hash": Vector.prev], ["seq": 4, "record_hash": Vector.prev.uppercased()],
      ["seq": 4], NSNull(),
    ] {
      XCTAssertNil(UsernameHead(json: bad), "\(bad)")
    }
  }

  // MARK: - The next free claim

  func testNextFreeClaimFollowsTheRegistryMonthRule() {
    let utc = TimeZone(identifier: "UTC")!
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = utc
      return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    // The registry's month_of vectors (gates.rs).
    XCTAssertEqual(UsernameClaimSlot.monthIndex(Date(timeIntervalSince1970: 1_792_627_200)), 2026 * 12 + 9)
    XCTAssertEqual(UsernameClaimSlot.monthIndex(Date(timeIntervalSince1970: 0)), 1970 * 12)
    XCTAssertEqual(UsernameClaimSlot.monthIndex(Date(timeIntervalSince1970: 1_767_225_599)), 2025 * 12 + 11)
    XCTAssertEqual(UsernameClaimSlot.monthIndex(Date(timeIntervalSince1970: 1_767_225_600)), 2026 * 12)
    XCTAssertEqual(UsernameClaimSlot.monthIndex(Date(timeIntervalSince1970: 1_709_164_800)), 2024 * 12 + 1)
    // e2e claims.rs: a September 2026 claim (START) blocks the phone through
    // September 2027 (START + 370 days) and frees it in October (START + 380).
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let free = UsernameClaimSlot.nextFreeClaim(after: start)
    XCTAssertEqual(free, day(2027, 10, 1))
    XCTAssertGreaterThan(free, start.addingTimeInterval(370 * 86_400))
    XCTAssertLessThanOrEqual(free, start.addingTimeInterval(380 * 86_400))
    // The spec's example: a claim on November 2, 2026.
    XCTAssertEqual(UsernameClaimSlot.nextFreeClaim(after: day(2026, 11, 2, 12)), day(2027, 12, 1))
    // The last day of a month rounds up: the mark may be dated next month.
    XCTAssertEqual(UsernameClaimSlot.nextFreeClaim(after: day(2026, 11, 30, 12)), day(2028, 1, 1))
    XCTAssertEqual(UsernameClaimSlot.nextFreeClaim(after: day(2026, 12, 31, 23)), day(2028, 2, 1))
    XCTAssertEqual(UsernameClaimSlot.nextFreeClaim(after: day(2027, 2, 27, 0)), day(2028, 3, 1))
    // Never early: at any claim time, the registry's mark_in_force still
    // holds one second before the date, for a mark from the claim's month
    // or the month after it (a write that crossed midnight).
    var claim = day(2026, 1, 1)
    while claim < day(2028, 1, 1) {
      let date = UsernameClaimSlot.nextFreeClaim(after: claim)
      let mark = UsernameClaimSlot.monthIndex(claim)
      let lateMark = UsernameClaimSlot.monthIndex(claim.addingTimeInterval(3600))
      for m in Set([mark, lateMark]) {
        XCTAssertTrue(UsernameClaimSlot.monthIndex(date.addingTimeInterval(-1)) >= m + 12, "\(claim)")
        XCTAssertGreaterThan(UsernameClaimSlot.monthIndex(date), m + 12, "\(claim)")
      }
      // At most one month late.
      XCTAssertLessThanOrEqual(UsernameClaimSlot.monthIndex(date), mark + 14, "\(claim)")
      claim = claim.addingTimeInterval(11 * 3600 + 17)
    }
  }
  func testAClaimSavesTheRegistryDateAndARestoreSavesNone() throws {
    let utc = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-02 12:00 UTC
    let claimed = UsernameBinding(
      walletKey: "wallet-A", network: "mainnet", handle: "alice", displayHandle: "Alice",
      subaddress: Vector.owner, genesisHash: Vector.genesis, record: "record", claimedAt: utc)
    let store = UsernameStore(persistence: RetireMemory())
    try store.accept(claimed)
    XCTAssertEqual(store.state.nextFreeClaim, Date(timeIntervalSince1970: 1_827_619_200))  // 2027-12-01 UTC
    let restored = UsernameStore(persistence: RetireMemory())
    try restored.accept(claimed, usesFreeClaim: false)
    XCTAssertNil(restored.state.nextFreeClaim)
    XCTAssertNil(restored.inviteHiddenUntil)
    XCTAssertNil(restored.nameState(for: claimed).nextFreeClaim)
  }

  // MARK: - Retire

  func testRetireSignsTheTombstoneAtTheHeadAndForgetsTheName() async throws {
    let store = try store()
    let other = PendingUsernameClaim(
      walletKey: "wallet-B", network: "mainnet", handle: "bobby", displayHandle: "Bobby", subaddress: "b",
      nonce: "", unsignedRecord: "", recordHash: "", ownerSignature: "", registrarKey: "", rules: "", rulesHash: "")
    try store.savePending(other)
    let free = try XCTUnwrap(store.state.nextFreeClaim)
    XCTAssertTrue(store.nameState(for: binding(in: store)).retireAllowed)
    var posted: [String: Any] = [:]
    serve(
      lookup: (200, live),
      post: (201, ["handle": "alice", "record": UsernameDevice.base64URL(Self.data(hex: Vector.record))]),
      check: { posted = $0 })
    try await retire(client(), store)
    XCTAssertEqual(paths, ["GET /v1/handles/alice", "POST /v1/handles/alice/records"])
    XCTAssertEqual(posted["record"] as? String, UsernameDevice.base64URL(Self.data(hex: Vector.unsigned)))
    XCTAssertEqual(posted["owner_signatures"] as? [String], [Vector.ownerSignature])
    XCTAssertEqual(posted.count, 2)
    // The name is gone; another wallet's saved claim and the free claim date stay.
    XCTAssertNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
    XCTAssertEqual(store.state.pending?.handle, "bobby")
    XCTAssertEqual(store.state.nextFreeClaim, free)
    XCTAssertEqual(store.inviteHiddenUntil, free)
    XCTAssertFalse(store.hasLocalClaimSlot)
  }
  func testRetireForgetsTheNamesOwnSavedClaim() async throws {
    let store = try store()
    let own = PendingUsernameClaim(
      walletKey: "wallet-A", network: "mainnet", handle: "alice", displayHandle: "Alice", subaddress: Vector.owner,
      nonce: "", unsignedRecord: "", recordHash: Vector.genesis, ownerSignature: "", registrarKey: "", rules: "",
      rulesHash: "")
    try store.savePending(own)
    serve(lookup: (200, live), post: (201, ["handle": "alice", "record": UsernameDevice.base64URL(Self.data(hex: Vector.record))]))
    try await retire(client(), store)
    XCTAssertNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
  }
  func testANoticeOrTermsHoldRetiresAtTheHoldsHead() async throws {
    for reason in [UsernameHoldReason.notice, .terms] {
      let store = try store()
      var posted: [String: Any] = [:]
      serve(
        lookup: (451, heldBody(reason)),
        post: (201, ["handle": "alice", "record": UsernameDevice.base64URL(Self.data(hex: Hold.record))]),
        check: { posted = $0 })
      try await retire(client(registrarKey: Hold.key), store)
      XCTAssertEqual(posted["record"] as? String, UsernameDevice.base64URL(Self.data(hex: Vector.unsigned)), reason.rawValue)
      XCTAssertTrue(store.state.bindings.isEmpty, reason.rawValue)
      XCTAssertTrue(store.holds.isEmpty, reason.rawValue)
    }
  }
  func testAnOrderOrSanctionsHoldOffersNoRetireAndSignsNothing() async throws {
    for reason in [UsernameHoldReason.order, .sanctions] {
      let store = try store()
      serve(lookup: (451, heldBody(reason)))
      do {
        try await retire(client(registrarKey: Hold.key), store, sign: noSignature)
        XCTFail("Retired under an \(reason) hold")
      } catch UsernameFailure.held(let hold) {
        XCTAssertEqual(hold.reason, reason)
      }
      XCTAssertEqual(paths, ["GET /v1/handles/alice"])
      // The name and the hold stay; the @name screen shows the hold.
      let state = store.nameState(for: binding(in: store))
      XCTAssertEqual(state.heldReason, reason)
      XCTAssertEqual(state.heldAt, Date(timeIntervalSince1970: Hold.heldAt))
      XCTAssertFalse(state.retireAllowed)
    }
  }
  func testAHoldThatTightensBeforeThePostKeepsTheName() async throws {
    let store = try store()
    serve(lookup: (200, live), post: (451, heldBody(.sanctions)))
    do {
      try await retire(client(registrarKey: Hold.key), store)
      XCTFail("Retired under a sanctions hold")
    } catch UsernameFailure.held(let hold) {
      XCTAssertEqual(hold.reason, .sanctions)
    }
    XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
    XCTAssertFalse(store.nameState(for: binding).retireAllowed)
  }
  func testAHoldWithABadSignatureGivesTheGenericErrorAndNoReason() async throws {
    let store = try store()
    serve(lookup: (451, heldBody(.notice, signature: Hold.signatures[.order])))
    do {
      try await retire(client(registrarKey: Hold.key), store, sign: noSignature)
      XCTFail("Retired with an unchecked hold")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        String(localized: "The username service couldn't complete the request. Please try again."))
    }
    XCTAssertTrue(store.holds.isEmpty)
    XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
    XCTAssertTrue(store.nameState(for: binding).retireAllowed)
  }
  func testAReplyThatFailsItsCheckKeepsTheNameAndARetryFinishes() async throws {
    let store = try store()
    var tampered = Self.data(hex: Vector.record)
    tampered[tampered.count - 1] ^= 1
    serve(lookup: (200, live), post: (201, ["handle": "alice", "record": UsernameDevice.base64URL(tampered)]))
    do {
      try await retire(client(), store)
      XCTFail("Accepted a reply without the registrar's countersignature")
    } catch UsernameFailure.verification {}
    XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
    // The retire landed: the next try finds the tombstone and signs nothing.
    var retired = live
    retired["tombstoned"] = true
    retired["owner"] = NSNull()
    serve(lookup: (200, retired))
    try await retire(client(), store, sign: noSignature)
    XCTAssertTrue(store.state.bindings.isEmpty)
  }
  func testANameThatIsGoneOrRetiredAlreadyIsForgotten() async throws {
    // (lookup, post): erased at an epoch; or the lookup ran before an
    // earlier retire landed.
    let rows: [(String, (Int, Any), (Int, Any)?)] = [
      ("erased", (404, ["error": ["code": "handle.not_found"]]), nil),
      ("landed", (200, live), (409, ["error": ["code": "chain.record_after_tombstone"]])),
    ]
    for (name, lookup, post) in rows {
      let store = try store()
      serve(lookup: lookup, post: post)
      try await retire(client(), store, sign: post == nil ? noSignature : nil)
      XCTAssertTrue(store.state.bindings.isEmpty, name)
      XCTAssertNotNil(store.state.nextFreeClaim, name)
    }
  }
  func testRetireStopsOnALookupThatIsNotThisName() async throws {
    let rows: [(String, (inout [String: Any]) -> Void)] = [
      ("another genesis", { $0["genesis_hash"] = Vector.prev }),
      ("another owner", { $0["owner"] = "another-address" }),
      ("another name", { $0["handle"] = "alicf" }),
      ("no head", { $0["head"] = nil }),
      ("a genesis head that is not ours", { $0["head"] = ["seq": 0, "record_hash": Vector.prev] }),
      ("no tombstone flag", { $0["tombstoned"] = nil }),
    ]
    for (name, change) in rows {
      let store = try store()
      var reply = live
      change(&reply)
      serve(lookup: (200, reply))
      do {
        try await retire(client(), store, sign: noSignature)
        XCTFail("Retired: \(name)")
      } catch UsernameFailure.verification {}
      XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"), name)
    }
  }
  func testAWalletChangeStopsTheRetireBeforeItPosts() async throws {
    let store = try store()
    serve(lookup: (200, live))
    var calls = 0
    do {
      try await retire(
        client(), store,
        current: {
          calls += 1
          return calls < 3
        })
      XCTFail("Posted after a wallet change")
    } catch UsernameFailure.walletChanged {}
    XCTAssertEqual(paths, ["GET /v1/handles/alice"])
    XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
  }

  // MARK: - The state of the own name

  func testStatusSavesAHoldAndALiveAnswerClearsIt() async throws {
    let store = try store()
    serve(lookup: (451, heldBody(.order)))
    let held = try await client(registrarKey: Hold.key).status(of: binding(in: store), store: store)
    guard case .held(let hold) = held else { return XCTFail("\(held)") }
    XCTAssertEqual(hold.reason, .order)
    XCTAssertEqual(store.nameState(for: binding).heldReason, .order)
    serve(lookup: (200, live))
    let back = try await client(registrarKey: Hold.key).status(of: binding(in: store), store: store)
    XCTAssertEqual(back, .live(UsernameHead(seq: 4, recordHash: Vector.prev)))
    XCTAssertNil(store.nameState(for: binding).hold)
    XCTAssertTrue(store.nameState(for: binding).retireAllowed)
    // Nothing else changed.
    XCTAssertNotNil(store.binding(walletKey: "wallet-A", network: "mainnet"))
  }
  func testAHeldNameKeepsTheSavedClaimInClaimAndRecheck() async throws {
    let store = UsernameStore(persistence: RetireMemory())
    let pending = PendingUsernameClaim(
      walletKey: "wallet-A", network: "mainnet", handle: "alice", displayHandle: "Alice", subaddress: Vector.owner,
      nonce: String(repeating: "0", count: 64), unsignedRecord: "request", recordHash: Vector.genesis,
      ownerSignature: "signature", registrarKey: Hold.key, rules: "rules", rulesHash: String(repeating: "c", count: 64))
    try store.savePending(pending)
    for wallet in ["wallet-A", "wallet-B"] {
      serve(lookup: (451, heldBody(.notice, head: ["seq": 0, "record_hash": Vector.genesis])))
      do {
        _ = try await client(registrarKey: Hold.key).claim(
          displayHandle: wallet == "wallet-A" ? "Alice" : "Bobby", walletKey: wallet, network: "mainnet",
          store: store,
          makeSubaddress: { XCTFail("No new address"); throw UsernameFailure.verification },
          sign: noSignature, claimKey: { XCTFail("No claim key"); throw UsernameFailure.verification },
          ownsSubaddress: { _ in XCTFail("No wallet check"); return false }, isCurrentWallet: { true })
        XCTFail("Claimed a held name")
      } catch {
        // The same name shows the held (taken) text; another name waits for the saved claim.
        let expected: UsernameFailure = wallet == "wallet-A" ? .unavailable : .pendingClaim
        XCTAssertEqual(error.localizedDescription, expected.localizedDescription, wallet)
      }
      XCTAssertEqual(paths, ["GET /v1/handles/alice"], wallet)
      XCTAssertEqual(store.state.pending?.recordHash, Vector.genesis, wallet)
      XCTAssertEqual(store.holds.values.first?.reason, .notice, wallet)
    }
  }
  func testAFreeNameLookupThatIsHeldStopsTheClaimBeforeANonce() async throws {
    let store = UsernameStore(persistence: RetireMemory())
    paths = []
    RetireURLProtocol.handler = { [weak self] request in
      let path = request.url?.path ?? ""
      self?.paths.append(path)
      switch path {
      case "/v1/info":
        return (200, [
          "registrar_key": Hold.key, "rules_hash": String(repeating: "c", count: 64), "network": "mainnet",
          "zone": "monero.one", "open": true,
        ])
      case "/v1/rules": return (200, Data("rules".utf8))
      case "/v1/handles/alice": return (451, self!.heldBody(.order))
      default:
        XCTFail("Unexpected \(path)")
        throw URLError(.badURL)
      }
    }
    do {
      _ = try await client(registrarKey: Hold.key).claim(
        displayHandle: "alice", walletKey: "wallet-A", network: "mainnet", store: store,
        makeSubaddress: { XCTFail("No new address"); throw UsernameFailure.verification },
        sign: noSignature, claimKey: { XCTFail("No claim key"); throw UsernameFailure.verification },
        ownsSubaddress: { _ in XCTFail("No wallet check"); return false }, isCurrentWallet: { true })
      XCTFail("Claimed a held name")
    } catch UsernameFailure.held(let hold) {
      XCTAssertEqual(hold.reason, .order)
      XCTAssertEqual(UsernameFailure.held(hold).localizedDescription, UsernameFailure.unavailable.localizedDescription)
    }
    XCTAssertEqual(paths, ["/v1/info", "/v1/rules", "/v1/handles/alice"])
    XCTAssertNil(store.state.pending)
  }
}

private final class RetireMemory: UsernamePersistence {
  var state = UsernameLocalState()
  func read() throws -> UsernameLocalState { state }
  func write(_ state: UsernameLocalState) throws { self.state = state }
}

private final class RetireURLProtocol: URLProtocol {
  /// A body is a JSON object, or raw bytes.
  static var handler: ((URLRequest) throws -> (Int, Any))?
  static func body(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
      }
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard let handler = Self.handler else { throw URLError(.badServerResponse) }
      let (status, body) = try handler(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try (body as? Data) ?? JSONSerialization.data(withJSONObject: body))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
