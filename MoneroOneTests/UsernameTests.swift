import DeviceCheck
import UIKit
import XCTest

@testable import MoneroOne

@MainActor
final class UsernameTests: XCTestCase {
  // Public wallet2-alice-prefix-1 vector from oah/vectors/chains.json and rules.json.
  // Contains no private keys and is never submitted to a public server.
  private static let fixture =
    try! JSONSerialization.jsonObject(
      with: Data(
        base64Encoded:
          "eyJyZWNvcmQiOiAiVDBGSU1RRUZZV3hwWTJVQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBcXMtUHZWV19HaTJubTR0bXNZV2JwNEFISGdmSHpadzBYeUFNeUo2a21DYURVZWRQQnh1MXBTTDdlbmU2V2J5N05oT3NNWVdSa19Za1Z3MUdadVJDS0J3QWFaVXpVa3hDNk01bkxONlB0RWhObm53aUg3SnZvZHJReFFnWlJ4OTNXQ05qYTB5ZUsxOFpJU29QVmhpaktqdUhkMGtUdkRaYWU1alJxeU1aZzJXNFBJUFFBWmo2YVFUYzE0Mkg5ZC1XZ1NNYnFIZFp6bFA4cjZjM1VOY195blFOakx1T0V2elFXUUJQNl9abU9pTFFNRU16VnVqTlMwelZSTDNNMjlpYXJBZyIsICJoYXNoIjogIjI5ZDBkNmRjZDVkZDMxNTMzZGJiNjkyMzAwMDI0MTQ0YjgwNDViNzg5OGFlYzMxNDI3Y2E0OGU3YzdlYWY2MDciLCAib3duZXIiOiAiODlHZTZ5cHQ3QTJKaVA2d3R5RFZmV2VVOWF3dm56ckw0NHlpNjF3V0JhcFlUdUZkbUtRc2Y3dkRBaXhBQjhxem45Yk5vM0w3MzhoM3JQdnR6Rzg2eXhyNTFvd2dGdngiLCAia2V5IjogIjQ5YmRmYTY1MjU4MGU3ZDc1NjcyYmUzZDcwOGE4YTBmOWMzZTQyNGEzZWMwODgxODQwNmZiMzkyNWViYjAxN2UiLCAicnVsZXMiOiAib2FoL3J1bGVzL3YxXG5oYW5kbGUubWluX2xlbj0zXG5oYW5kbGUubWF4X2xlbj0xNVxuaGFuZGxlLmNoYXJzZXQ9YS16MC05X1xuaGFuZGxlLmZpcnN0PWEtelxuaGFuZGxlLm5vX2RvdWJsZV91bmRlcnNjb3JlPTFcbnNrZWxldG9uLmRyb3A9X1xuc2tlbGV0b24ubWFwPTBvMWxpbDVzXG5za2VsZXRvbi5yZXBsYWNlPXJuPm0sdnY+d1xuYmxvY2subWF0Y2g9bmFtZSxza2VsZXRvblxuZGlzcGxheS5jaGFyc2V0PTIwLTdlXG5kaXNwbGF5Lm1pbl9sZW49MVxuZGlzcGxheS5tYXhfbGVuPTMyXG5kaXNwbGF5LmJsb2NrX21hdGNoPWFsbnVtX3NrZWxldG9uXG5jbGFpbXMucGVyX2RldmljZT0xXG5jbGFpbXMucGVyaW9kX21vbnRocz0xMlxucm90YXRlLm1heF9wZXJfeWVhcj0xMlxuYmxvY2suY29udGFpbnM9YW5vbmVyb1xuYmxvY2suY29udGFpbnM9YmluYW5jZVxuYmxvY2suY29udGFpbnM9Yml0ZmluZXhcbmJsb2NrLmNvbnRhaW5zPWJpdHN0YW1wXG5ibG9jay5jb250YWlucz1ieWJpdFxuYmxvY2suY29udGFpbnM9Y2FrZXdhbGxldFxuYmxvY2suY29udGFpbnM9Y29pbmJhc2VcbmJsb2NrLmNvbnRhaW5zPWZlYXRoZXJ3YWxsZXRcbmJsb2NrLmNvbnRhaW5zPWdhdGVpb1xuYmxvY2suY29udGFpbnM9aHVvYmlcbmJsb2NrLmNvbnRhaW5zPWt1Y29pblxuYmxvY2suY29udGFpbnM9bWV0YW1hc2tcbmJsb2NrLmNvbnRhaW5zPW1vbmVyb1xuYmxvY2suY29udGFpbnM9bW9uZXJ1am9cbmJsb2NrLmNvbnRhaW5zPW15bW9uZXJvXG5ibG9jay5jb250YWlucz10cmFkZW9ncmVcbmJsb2NrLmNvbnRhaW5zPXRyZXpvclxuYmxvY2suZXhhY3Q9YWJ1c2VcbmJsb2NrLmV4YWN0PWFjY291bnRcbmJsb2NrLmV4YWN0PWFjY291bnRzXG5ibG9jay5leGFjdD1hZG1pblxuYmxvY2suZXhhY3Q9YWRtaW5pc3RyYXRvclxuYmxvY2suZXhhY3Q9YXBpXG5ibG9jay5leGFjdD1hcHBcbmJsb2NrLmV4YWN0PWFwcHNcbmJsb2NrLmV4YWN0PWFzc2V0c1xuYmxvY2suZXhhY3Q9YXV0aFxuYmxvY2suZXhhY3Q9YXV0b2NvbmZpZ1xuYmxvY2suZXhhY3Q9YXV0b2Rpc2NvdmVyXG5ibG9jay5leGFjdD1iZXRhXG5ibG9jay5leGFjdD1iaWxsaW5nXG5ibG9jay5leGFjdD1ibG9nXG5ibG9jay5leGFjdD1jZG5cbmJsb2NrLmV4YWN0PWNvbXBsaWFuY2VcbmJsb2NrLmV4YWN0PWNvbnRhY3RcbmJsb2NrLmV4YWN0PWRldlxuYmxvY2suZXhhY3Q9ZG5zXG5ibG9jay5leGFjdD1kb2NzXG5ibG9jay5leGFjdD1kb25hdGVcbmJsb2NrLmV4YWN0PWVwb2NoXG5ibG9jay5leGFjdD1leHBsb3JlclxuYmxvY2suZXhhY3Q9ZnRwXG5ibG9jay5leGFjdD1oZWxwXG5ibG9jay5leGFjdD1oZWxwZGVza1xuYmxvY2suZXhhY3Q9aG9zdG1hc3RlclxuYmxvY2suZXhhY3Q9aW1hcFxuYmxvY2suZXhhY3Q9aW5mb1xuYmxvY2suZXhhY3Q9bGVnYWxcbmJsb2NrLmV4YWN0PWxvZ1xuYmxvY2suZXhhY3Q9bG9naW5cbmJsb2NrLmV4YWN0PW1haWxcbmJsb2NrLmV4YWN0PW1haWxlcl9kYWVtb25cbmJsb2NrLmV4YWN0PW1pcnJvclxuYmxvY2suZXhhY3Q9bWlycm9yc1xuYmxvY2suZXhhY3Q9bW9kZXJhdG9yXG5ibG9jay5leGFjdD1ub2RlXG5ibG9jay5leGFjdD1ub2Rlc1xuYmxvY2suZXhhY3Q9bm9yZXBseVxuYmxvY2suZXhhY3Q9bm90aWZpY2F0aW9uc1xuYmxvY2suZXhhY3Q9b2ZmaWNpYWxcbmJsb2NrLmV4YWN0PW9uaW9uXG5ibG9jay5leGFjdD1vcGVyYXRvclxuYmxvY2suZXhhY3Q9cG9wXG5ibG9jay5leGFjdD1wb3AzXG5ibG9jay5leGFjdD1wb3N0bWFzdGVyXG5ibG9jay5leGFjdD1wcml2YWN5XG5ibG9jay5leGFjdD1yZWNvdmVyeVxuYmxvY2suZXhhY3Q9cmVmdW5kXG5ibG9jay5leGFjdD1yZWZ1bmRzXG5ibG9jay5leGFjdD1yZWdpc3RyYXJcbmJsb2NrLmV4YWN0PXJlZ2lzdHJ5XG5ibG9jay5leGFjdD1yZWxheVxuYmxvY2suZXhhY3Q9cm9vdFxuYmxvY2suZXhhY3Q9c2VjdXJpdHlcbmJsb2NrLmV4YWN0PXNtdHBcbmJsb2NrLmV4YWN0PXNuYXBzaG90XG5ibG9jay5leGFjdD1zbmFwc2hvdHNcbmJsb2NrLmV4YWN0PXN0YWZmXG5ibG9jay5leGFjdD1zdGFnaW5nXG5ibG9jay5leGFjdD1zdGF0aWNcbmJsb2NrLmV4YWN0PXN0YXR1c1xuYmxvY2suZXhhY3Q9c3Rld2FyZFxuYmxvY2suZXhhY3Q9c3VwcG9ydFxuYmxvY2suZXhhY3Q9c3lzYWRtaW5cbmJsb2NrLmV4YWN0PXN5c3RlbVxuYmxvY2suZXhhY3Q9dGVhbVxuYmxvY2suZXhhY3Q9dGVzdFxuYmxvY2suZXhhY3Q9dmVyaWZpZWRcbmJsb2NrLmV4YWN0PXZlcmlmeVxuYmxvY2suZXhhY3Q9d2VibWFpbFxuYmxvY2suZXhhY3Q9d2VibWFzdGVyXG5ibG9jay5leGFjdD13aXRuZXNzXG5ibG9jay5leGFjdD13d3dcbmJsb2NrLnByZWZpeD1hdG9taWNcbmJsb2NrLnByZWZpeD1ka2ltXG5ibG9jay5wcmVmaXg9ZWRnZVxuYmxvY2sucHJlZml4PWV4b2R1c1xuYmxvY2sucHJlZml4PWtyYWtlblxuYmxvY2sucHJlZml4PWxlZGdlclxuYmxvY2sucHJlZml4PXRydXN0XG4iLCAicnVsZXNIYXNoIjogImM2NWZmZDQxNjIxY2IyZGIyNmZmZTg3YTkwZTA3OTJhNjQ4NDM0ZGZiZmIwNzdjZDVlZDZkZjQ1ODlhMzA4ZDQifQ=="
      )!) as! [String: String]
  private var f: [String: String] { Self.fixture }
  private func pending(recordHash: String? = nil) -> PendingUsernameClaim {
    PendingUsernameClaim(
      walletKey: "wallet-A", network: "mainnet", handle: "alice", displayHandle: "Alice",
      subaddress: f["owner"]!, nonce: String(repeating: "0", count: 64),
      unsignedRecord: "public-test-request",
      recordHash: recordHash ?? f["hash"]!, ownerSignature: "public-test-signature",
      registrarKey: f["key"]!, rules: f["rules"]!, rulesHash: f["rulesHash"]!)
  }
  private var info: [String: Any] {
    [
      "registrar_key": f["key"]!, "rules_hash": f["rulesHash"]!, "network": "mainnet",
      "zone": "monero.one", "open": true,
    ]
  }
  private func failure(_ error: Error) -> String? { (error as? UsernameFailure)?.localizedDescription }
  private func binding(
    wallet: String = "wallet-A", network: String = "mainnet", hash: String = "hash"
  ) -> UsernameBinding {
    UsernameBinding(
      walletKey: wallet, network: network, handle: "joe", displayHandle: "Joe",
      subaddress: "public-test-address",
      genesisHash: hash, record: "record", claimedAt: Date(timeIntervalSince1970: 1_800_000_000))
  }
  private func client(
    tokens: UsernameDeviceTokens = FakeDeviceTokens(), allowDevProof: Bool = false
  ) -> UsernameRegistry {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UsernameURLProtocol.self]
    return UsernameRegistry(
      configuration: UsernameConfiguration(
        url: URL(string: "http://localhost:8787")!, registrarKey: f["key"]!,
        rulesHash: f["rulesHash"]!, termsVersion: "test-terms-v1"), session: URLSession(configuration: config),
      deviceTokens: tokens, allowDevProof: allowDevProof)
  }
  private func claim(
    _ client: UsernameRegistry, _ store: UsernameStore, handle: String = "Alice",
    wallet: String = "wallet-A", network: String = "mainnet",
    owns: (String) async throws -> Bool = { _ in false }, current: @escaping () -> Bool = { true }
  ) async throws -> UsernameBinding {
    try await client.claim(
      displayHandle: handle, walletKey: wallet, network: network, store: store,
      makeSubaddress: {
        XCTFail("Recovery must not allocate a new subaddress")
        throw UsernameFailure.verification
      },
      sign: { _, _ in
        XCTFail("Recovery must not sign another claim")
        throw UsernameFailure.verification
      },
      claimKey: {
        XCTFail("Recovery must not read the claim key")
        throw UsernameFailure.verification
      }, ownsSubaddress: owns, isCurrentWallet: current)
  }
  /// `GET /v1/handles/alice` as the registry answers for a held name, with
  /// the fixture's record as the whole chain.
  private func found(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var reply: [String: Any] = [
      "handle": "alice", "genesis_hash": f["hash"]!, "owner": f["owner"]!, "tombstoned": false,
      "head": ["seq": 0, "record_hash": f["hash"]!],
      "records": [["seq": 0, "type": "genesis", "record_hash": f["hash"]!, "record": f["record"]!]],
    ]
    change(&reply)
    return reply
  }
  /// A registry that holds alice: any request after the lookup (a nonce or
  /// a claim) fails the test.
  private func serve(_ reply: [String: Any], network: String = "mainnet") {
    UsernameURLProtocol.handler = { [info, f] request in
      var info = info
      info["network"] = network
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("GET", "/v1/info"): return (200, info)
      case ("GET", "/v1/rules"): return (200, Data(f["rules"]!.utf8))
      case ("GET", "/v1/handles/alice"): return (200, reply)
      default:
        XCTFail("A held name must not send \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
  }
  override func tearDown() {
    UsernameURLProtocol.handler = nil
    super.tearDown()
  }

  func testFixedRulesAndCanonicalShortForms() throws {
    XCTAssertEqual(try UsernameRules.normalize("XMR_Garden_Club"), "xmr_garden_club")
    XCTAssertEqual(try UsernameRules.normalize("WWWWWWWWWWWWWWW"), "wwwwwwwwwwwwwww")
    for invalid in ["ab", "abcdefghijklmnop", "a__b", "1abc", "joe@monero.one", "admin", "jóe"] {
      XCTAssertThrowsError(try UsernameRules.normalize(invalid))
    }
    XCTAssertEqual(binding().shortName, "@Joe")
    XCTAssertEqual(binding().externalAddress, "joe@monero.one")
  }
  func testBindingStaysWithItsWalletAndNetworkAfterReload() throws {
    let disk = UsernameMemory()
    let store = UsernameStore(persistence: disk)
    try store.accept(binding())
    let reloaded = UsernameStore(persistence: disk)
    XCTAssertEqual(reloaded.binding(walletKey: "wallet-A", network: "mainnet")?.shortName, "@Joe")
    XCTAssertNil(reloaded.binding(walletKey: "wallet-B", network: "mainnet"))
    XCTAssertNil(reloaded.binding(walletKey: "wallet-A", network: "testnet"))
    XCTAssertFalse(reloaded.hasLocalClaimSlot)
    XCTAssertThrowsError(try reloaded.accept(binding(hash: "another-genesis")))
  }
  func testFailedPersistenceDoesNotPublishClaimOrLosePending() throws {
    let disk = UsernameMemory()
    let store = UsernameStore(persistence: disk)
    try store.savePending(pending())
    disk.failWrites = true
    XCTAssertThrowsError(try store.accept(binding()))
    XCTAssertNotNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
    XCTAssertNil(store.state.nextFreeClaim)
  }
  func testOnlyOneClaimMayRunPerStore() throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.beginClaim()
    XCTAssertThrowsError(try store.beginClaim())
    store.endClaim()
    XCTAssertNoThrow(try store.beginClaim())
    store.endClaim()
  }
  func testLostReplyRecoversExactWallet2GenesisWithoutResigning() async throws {
    let disk = UsernameMemory()
    let store = UsernameStore(persistence: disk)
    // The claim was saved before its POST, and the reply was lost.
    try store.savePending(pending())
    let record = f["record"]!
    var posts = 0
    // The registry cannot be reached: the result stays unknown.
    UsernameURLProtocol.handler = { request in
      if request.httpMethod == "POST" { posts += 1 }
      throw URLError(.timedOut)
    }
    do {
      _ = try await claim(client(), store)
      XCTFail("Expected an unreachable registry")
    } catch {}
    XCTAssertEqual(posts, 0)
    XCTAssertNotNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
    UsernameURLProtocol.handler = { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/v1/handles/alice")
      return (200, ["records": [["record": record]]])
    }
    let reloaded = UsernameStore(persistence: disk)
    let accepted = try await claim(client(), reloaded)
    XCTAssertEqual(accepted.genesisHash, f["hash"])
    XCTAssertEqual(accepted.walletKey, "wallet-A")
    XCTAssertNil(reloaded.state.pending)
    XCTAssertEqual(reloaded.state.bindings.count, 1)
  }
  func testTamperedResponseDoesNotConsumeLocalSlot() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    let record = f["record"]!
    let altered = String(record.dropLast(2)) + "AA"
    UsernameURLProtocol.handler = { _ in (200, ["records": [["record": altered]]]) }
    do {
      _ = try await claim(client(), store)
      XCTFail("Accepted a forged signature")
    } catch {
      XCTAssertEqual(
        (error as? UsernameFailure)?.localizedDescription,
        UsernameFailure.verification.localizedDescription)
    }
    XCTAssertNotNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
    XCTAssertTrue(store.hasLocalClaimSlot)
  }
  func testChangedWalletCannotStartOrResumeClaim() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    UsernameURLProtocol.handler = { _ in
      XCTFail("A stale wallet must not make a request")
      return (500, [String: Any]())
    }
    do {
      _ = try await claim(client(), store, current: { false })
      XCTFail("Expected wallet guard")
    } catch {
      XCTAssertEqual(
        (error as? UsernameFailure)?.localizedDescription,
        UsernameFailure.walletChanged.localizedDescription)
    }
    XCTAssertNotNil(store.state.pending)
  }
  func testRegistrarUnavailableCodeReleasesPendingForAnotherChoice() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    // The saved claim's name is still free: the claim is cleared and a new
    // one starts, with a new nonce and a new signature.
    try store.savePending(pending())
    let nonce = String(repeating: "ab", count: 32)
    var made = 0
    var signed = 0
    var claimNonce: String?
    var claimTerms: String?
    UsernameURLProtocol.handler = { [info, f] request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("GET", "/v1/handles/alice"): return (404, ["error": ["code": "handle.not_found"]])
      case ("GET", "/v1/info"): return (200, info)
      case ("GET", "/v1/rules"): return (200, Data(f["rules"]!.utf8))
      case ("POST", "/v1/nonce"): return (200, ["nonce": nonce])
      case ("POST", "/v1/claims"):
        claimNonce = UsernameURLProtocol.body(request)["nonce"] as? String
        claimTerms = UsernameURLProtocol.body(request)["terms_version"] as? String
        return (409, ["error": ["code": "name.unavailable"]])
      default:
        XCTFail("Unexpected request \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
    do {
      _ = try await client().claim(
        displayHandle: "Alice", walletKey: "wallet-A", network: "mainnet", store: store,
        makeSubaddress: { [f] in
          made += 1
          return f["owner"]!
        },
        sign: { _, _ in
          signed += 1
          return "public-test-signature"
        }, claimKey: { Self.claimKey }, ownsSubaddress: { _ in false }, isCurrentWallet: { true })
      XCTFail("Expected unavailable")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.unavailable.localizedDescription)
    }
    XCTAssertEqual(made, 1)
    XCTAssertEqual(signed, 1)
    XCTAssertEqual(claimNonce, nonce)
    XCTAssertEqual(claimTerms, "test-terms-v1")
    XCTAssertNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
  }
  func testNameHeldByAnotherOwnerClearsPendingWithTheTakenMessage() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    // This phone signed another genesis than the one the registry holds.
    try store.savePending(pending(recordHash: String(repeating: "1", count: 64)))
    UsernameURLProtocol.handler = { [info, f] request in
      XCTAssertEqual(request.httpMethod, "GET")
      switch request.url?.path ?? "" {
      case "/v1/handles/alice": return (200, ["records": [["record": f["record"]!]]])
      case "/v1/info": return (200, info)
      case "/v1/rules": return (200, Data(f["rules"]!.utf8))
      default:
        XCTFail("Unexpected request \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
    do {
      _ = try await claim(client(), store)
      XCTFail("Expected the taken message")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.unavailable.localizedDescription)
    }
    XCTAssertNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
    XCTAssertTrue(store.hasLocalClaimSlot)
  }
  func testAnotherWalletClaimWaitsOnlyWhileTheSavedResultIsUnknown() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    UsernameURLProtocol.handler = { request in
      XCTAssertEqual(request.url?.path, "/v1/handles/alice")
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await claim(client(), store, handle: "Bobby", wallet: "wallet-B")
      XCTFail("Expected the saved claim to block")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.pendingClaim.localizedDescription)
    }
    XCTAssertNotNil(store.state.pending)
    // The registry answers: wallet A's claim went through and used the phone's claim.
    UsernameURLProtocol.handler = { [f] request in
      XCTAssertEqual(request.url?.path, "/v1/handles/alice")
      return (200, ["records": [["record": f["record"]!]]])
    }
    do {
      _ = try await claim(client(), store, handle: "Bobby", wallet: "wallet-B")
      XCTFail("Expected no free claim")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.noFreeClaim.localizedDescription)
    }
    XCTAssertNil(store.state.pending)
    XCTAssertEqual(store.binding(walletKey: "wallet-A", network: "mainnet")?.handle, "alice")
    XCTAssertNil(store.binding(walletKey: "wallet-B", network: "mainnet"))
  }
  func testAnotherWalletClaimClearsASavedClaimForAFreeName() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    UsernameURLProtocol.handler = { request in
      if request.url?.path == "/v1/handles/alice" {
        return (404, ["error": ["code": "handle.not_found"]])
      }
      // Wallet B's own claim starts; stop it at the first request.
      XCTAssertEqual(request.url?.path, "/v1/info")
      throw URLError(.timedOut)
    }
    do {
      _ = try await claim(client(), store, handle: "Bobby", wallet: "wallet-B")
      XCTFail("Expected the stopped request")
    } catch {}
    XCTAssertNil(store.state.pending)
  }
  func testEarlierRequestThatLandsDuringTheNewClaimStillBinds() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    var lookups = 0
    UsernameURLProtocol.handler = { [info, f] request in
      XCTAssertEqual(request.httpMethod, "GET")
      switch request.url?.path ?? "" {
      case "/v1/handles/alice":
        lookups += 1
        // Free at the first check; the earlier request lands before the second.
        return lookups == 1
          ? (404, ["error": ["code": "handle.not_found"]])
          : (200, ["records": [["record": f["record"]!]]])
      case "/v1/info": return (200, info)
      case "/v1/rules": return (200, Data(f["rules"]!.utf8))
      default:
        XCTFail("Unexpected request \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
    let accepted = try await claim(client(), store)
    XCTAssertEqual(lookups, 2)
    XCTAssertEqual(accepted.genesisHash, f["hash"])
    XCTAssertNil(store.state.pending)
    XCTAssertEqual(store.binding(walletKey: "wallet-A", network: "mainnet")?.handle, "alice")
    // That claim ran on this phone: it used the free claim.
    XCTAssertFalse(store.hasLocalClaimSlot)
  }

  // MARK: - A name this wallet already holds

  func testOwnNameComesBackWithNoClaim() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    var paths: [String] = []
    let reply = found()
    UsernameURLProtocol.handler = { [info, f] request in
      paths.append((request.httpMethod ?? "GET") + " " + (request.url?.path ?? ""))
      switch request.url?.path ?? "" {
      case "/v1/info": return (200, info)
      case "/v1/rules": return (200, Data(f["rules"]!.utf8))
      case "/v1/handles/alice": return (200, reply)
      default: throw URLError(.badURL)
      }
    }
    // The helper fails the test on a new subaddress, a signature or a claim key.
    let restored = try await claim(client(), store, owns: { [f] in $0 == f["owner"]! })
    XCTAssertEqual(paths, ["GET /v1/info", "GET /v1/rules", "GET /v1/handles/alice"])
    XCTAssertEqual(restored.handle, "alice")
    XCTAssertEqual(restored.displayHandle, "Alice")
    XCTAssertEqual(restored.subaddress, f["owner"])
    XCTAssertEqual(restored.genesisHash, f["hash"])
    XCTAssertEqual(restored.record, f["record"])
    XCTAssertEqual(store.binding(walletKey: "wallet-A", network: "mainnet"), restored)
    XCTAssertNil(store.state.pending)
    // No claim ran on this phone: its free claim is still there.
    XCTAssertNil(store.state.nextFreeClaim)
    XCTAssertTrue(store.hasLocalClaimSlot)
  }
  func testNameOfAnotherWalletStaysUnavailable() async throws {
    // (the open wallet's subaddress, the lookup's owner field, the wallet is asked)
    let rows: [(String, String, Bool)] = [
      // The name points to a subaddress of another wallet.
      ("public-test-address", f["owner"]!, true),
      // The lookup names this wallet, but the signed record points elsewhere:
      // the wallet is never asked, so it lists no subaddress for it.
      ("public-test-address", "public-test-address", false),
    ]
    for (own, owner, asks) in rows {
      let store = UsernameStore(persistence: UsernameMemory())
      serve(found { $0["owner"] = owner })
      var asked: [String] = []
      do {
        _ = try await claim(
          client(), store,
          owns: {
            asked.append($0)
            return $0 == own
          })
        XCTFail("Restored a name of another wallet: \(owner)")
      } catch {
        XCTAssertEqual(failure(error), UsernameFailure.unavailable.localizedDescription, owner)
      }
      XCTAssertEqual(asked, asks ? [owner] : [], owner)
      XCTAssertTrue(store.state.bindings.isEmpty, owner)
      XCTAssertTrue(store.hasLocalClaimSlot, owner)
    }
  }
  func testTombstonedOldOrWrongNetworkRecordStaysUnavailable() async throws {
    let hash = f["hash"]!
    let record = f["record"]!
    let later = String(repeating: "2", count: 64)
    let genesis: [String: Any] = ["seq": 0, "type": "genesis", "record_hash": hash, "record": record]
    // (case, network, change to the lookup reply)
    let rows: [(String, String, (inout [String: Any]) -> Void)] = [
      ("tombstoned", "mainnet", { $0["tombstoned"] = true }),
      ("no tombstone flag", "mainnet", { $0["tombstoned"] = nil }),
      ("a later head", "mainnet", { $0["head"] = ["seq": 1, "record_hash": later] }),
      (
        "two records", "mainnet",
        {
          $0["head"] = ["seq": 1, "record_hash": later]
          $0["records"] = [genesis, ["seq": 1, "type": "rotate", "record_hash": later, "record": record]]
        }
      ),
      (
        "the record is not the named head", "mainnet",
        {
          $0["genesis_hash"] = later
          $0["head"] = ["seq": 0, "record_hash": later]
          $0["records"] = [["seq": 0, "type": "genesis", "record_hash": later, "record": record]]
        }
      ),
      (
        "a forged signature", "mainnet",
        {
          $0["records"] = [
            ["seq": 0, "type": "genesis", "record_hash": hash, "record": String(record.dropLast(2)) + "AA"]
          ]
        }
      ),
      ("another name", "mainnet", { $0["handle"] = "alicf" }),
      ("wrong network", "testnet", { _ in }),
    ]
    for (name, network, change) in rows {
      let store = UsernameStore(persistence: UsernameMemory())
      serve(found(change), network: network)
      var asked = 0
      do {
        _ = try await claim(
          client(), store, network: network,
          owns: { [f] in
            asked += 1
            return $0 == f["owner"]!
          })
        XCTFail("Restored \(name)")
      } catch {
        XCTAssertEqual(failure(error), UsernameFailure.unavailable.localizedDescription, name)
      }
      // A record that fails a check never makes the wallet list a subaddress.
      XCTAssertEqual(asked, 0, name)
      XCTAssertTrue(store.state.bindings.isEmpty, name)
      XCTAssertTrue(store.hasLocalClaimSlot, name)
    }
  }
  /// A seed restore on a new phone: the wallet lists only its first rows.
  /// The ownership check may list the subaddress first (it waits for the
  /// wallet), and the name then comes back as on the old phone.
  func testOwnNameComesBackAfterTheWalletListsItsSubaddress() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    serve(found())
    var listed: [String] = []
    let restored = try await claim(
      client(), store,
      owns: { [f] address in
        await Task.yield()
        guard address == f["owner"]! else { return false }
        listed.append(address)
        return true
      })
    XCTAssertEqual(listed, [f["owner"]!])
    XCTAssertEqual(restored.subaddress, f["owner"])
    XCTAssertEqual(store.binding(walletKey: "wallet-A", network: "mainnet"), restored)
    XCTAssertTrue(store.hasLocalClaimSlot)
  }
  /// The wallet's own cause shows, not "unavailable": a wallet file still
  /// opening, or a wallet change while it lists the subaddress.
  func testOwnNameShowsTheWalletsCauseWhenItCannotBeChecked() async throws {
    let rows: [(String, UsernameFailure, Bool)] = [
      ("still opening", .walletOpening, true),
      ("changed while it listed", .walletChanged, false),
    ]
    for (name, expected, throwsFromWallet) in rows {
      let store = UsernameStore(persistence: UsernameMemory())
      serve(found())
      var current = true
      do {
        _ = try await claim(
          client(), store,
          owns: { _ in
            if throwsFromWallet { throw expected }
            current = false
            return true
          }, current: { current })
        XCTFail("Restored \(name)")
      } catch {
        XCTAssertEqual(failure(error), expected.localizedDescription, name)
      }
      XCTAssertTrue(store.state.bindings.isEmpty, name)
      XCTAssertNil(store.state.pending, name)
    }
  }
  /// A registry reply with a missing field is a verification failure. It
  /// used to say "The wallet changed", which sent people to the wrong fix.
  func testABadRegistryReplyIsNotAWalletChange() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    var made = 0
    UsernameURLProtocol.handler = { [info, f] request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("GET", "/v1/info"): return (200, info)
      case ("GET", "/v1/rules"): return (200, Data(f["rules"]!.utf8))
      case ("GET", "/v1/handles/alice"): return (404, ["error": ["code": "handle.not_found"]])
      case ("POST", "/v1/nonce"): return (200, ["expires_at": 0])
      default:
        XCTFail("Unexpected request \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
    do {
      _ = try await client().claim(
        displayHandle: "Alice", walletKey: "wallet-A", network: "mainnet", store: store,
        makeSubaddress: { [f] in
          made += 1
          return f["owner"]!
        },
        sign: { _, _ in
          XCTFail("No signature without a nonce")
          return ""
        }, claimKey: { Self.claimKey }, ownsSubaddress: { _ in false }, isCurrentWallet: { true })
      XCTFail("Claimed with no nonce")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.verification.localizedDescription)
    }
    XCTAssertEqual(made, 1)
    XCTAssertNil(store.state.pending)
  }
  func testWalletOpeningHasItsOwnMessage() {
    XCTAssertEqual(
      UsernameFailure.walletOpening.localizedDescription,
      "Your wallet is still opening. Try again in a moment.")
    XCTAssertNotEqual(
      UsernameFailure.walletOpening.localizedDescription,
      UsernameFailure.walletChanged.localizedDescription)
  }
  func testLongestHomeNameFitsOneLineAtTheLargestStripSize() {
    // 375 pt iPhone: 16 pt screen margins, 24 pt strip padding, a 10 pt gap
    // and the chevron leave this width for the name.
    let chevron = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))!.size.width
    let available = 375 - 2 * 16 - 2 * 24 - 10 - chevron
    let name = NSAttributedString(
      string: "@mmmmmmmmmmmmmmm",
      attributes: [
        .font: UIFont.systemFont(ofSize: BalanceCard.usernameMaxSize, weight: .medium),
        .kern: -0.35,
      ])
    XCTAssertLessThanOrEqual(name.size().width, available)
    XCTAssertGreaterThan(BalanceCard.usernameMaxSize, 18)
  }
  func testOnlyTheSavedClaimsWalletOffersAClaim() throws {
    let store = UsernameStore(persistence: UsernameMemory())
    XCTAssertTrue(store.offersClaim(walletKey: "wallet-B", network: "mainnet"))
    try store.savePending(pending())
    XCTAssertTrue(store.offersClaim(walletKey: "wallet-A", network: "mainnet"))
    XCTAssertFalse(store.offersClaim(walletKey: "wallet-B", network: "mainnet"))
    XCTAssertFalse(store.offersClaim(walletKey: "wallet-A", network: "testnet"))
    try store.clearPending(walletKey: "wallet-A")
    XCTAssertTrue(store.offersClaim(walletKey: "wallet-B", network: "mainnet"))
  }
  func testDeletingAWalletClearsOnlyItsSavedClaim() throws {
    let store = UsernameStore(persistence: UsernameMemory())
    try store.savePending(pending())
    try store.clearPending(walletKey: "wallet-B")
    XCTAssertNotNil(store.state.pending)
    try store.clearPending(walletKey: "")
    XCTAssertNotNil(store.state.pending)
    try store.clearPending(walletKey: "wallet-A")
    XCTAssertNil(store.state.pending)
  }
  func testWalletIdentitySurvivesRescanAndRowRecreation() throws {
    let manager = WalletManager()
    let address = "4" + String(repeating: "A", count: 94)
    var wallet = WalletInfo(
      id: UUID(), name: "Daily", emoji: "💰", source: .seed(.polyseed), createdAt: Date(),
      restoreHeight: 0, syncResetCount: 0, userCreatedSubaddressIndices: [],
      cachedPrimaryAddress: address, cachedBalance: nil)
    wallet.derivedWalletId = "old-cache"
    manager.activeWallet = wallet
    let stable = manager.usernameWalletKey
    wallet.derivedWalletId = "new-cache-after-rescan"
    wallet.syncResetCount = 1
    manager.activeWallet = wallet
    XCTAssertEqual(manager.usernameWalletKey, stable)
    let recreated = WalletInfo(
      id: UUID(), name: "Restored", emoji: "💰", source: .seed(.polyseed), createdAt: Date(),
      restoreHeight: 0, syncResetCount: 0, userCreatedSubaddressIndices: [],
      cachedPrimaryAddress: address, cachedBalance: nil)
    manager.activeWallet = recreated
    XCTAssertEqual(manager.usernameWalletKey, stable)
    XCTAssertFalse(stable.isEmpty)
  }
  func testWrongRegistrarStopsBeforeCreatingAnAddress() async throws {
    let store = UsernameStore(persistence: UsernameMemory())
    UsernameURLProtocol.handler = { request in
      XCTAssertEqual(request.url?.path, "/v1/info")
      return (200, ["registrar_key": "untrusted-key"])
    }
    do {
      _ = try await claim(client(), store)
      XCTFail("Expected pinned-key failure")
    } catch {}
    XCTAssertNil(store.state.pending)
    XCTAssertTrue(store.state.bindings.isEmpty)
  }

  // MARK: - Device proof (registry README, "Device gates")

  /// The shared test vector: the key bytes 0x00 ... 0x1f.
  private static let claimKey = "6f19b34dced9cf703d2e0222e085d6a475695543cce6b912af942a541524ba6a"
  /// Starts a new claim for a free name and answers POST /v1/claims with
  /// `reply`. Gives the result and the `device` object of each claim POST.
  private func freshClaim(
    _ registry: UsernameRegistry, _ store: UsernameStore, reply: (Int, Any) = (500, [String: Any]())
  ) async -> (result: Result<UsernameBinding, Error>, devices: [[String: Any]]) {
    var devices: [[String: Any]] = []
    UsernameURLProtocol.handler = { [info, f] request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("GET", "/v1/handles/alice"): return (404, ["error": ["code": "handle.not_found"]])
      case ("GET", "/v1/info"): return (200, info)
      case ("GET", "/v1/rules"): return (200, Data(f["rules"]!.utf8))
      case ("POST", "/v1/nonce"): return (200, ["nonce": String(repeating: "ab", count: 32)])
      case ("POST", "/v1/claims"):
        devices.append(UsernameURLProtocol.body(request)["device"] as? [String: Any] ?? [:])
        return reply
      default:
        XCTFail("Unexpected request \(request.url?.path ?? "")")
        throw URLError(.badURL)
      }
    }
    do {
      let binding = try await registry.claim(
        displayHandle: "Alice", walletKey: "wallet-A", network: "mainnet", store: store,
        makeSubaddress: { [f] in f["owner"]! }, sign: { _, _ in "public-test-signature" },
        claimKey: { Self.claimKey }, ownsSubaddress: { _ in false }, isCurrentWallet: { true })
      return (.success(binding), devices)
    } catch {
      return (.failure(error), devices)
    }
  }
  private func failure(_ result: Result<UsernameBinding, Error>) -> String? {
    guard case .failure(let error) = result else { return nil }
    return failure(error)
  }
  private static func unbase64URL(_ text: String) -> Data? {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: standard)
  }

  func testClaimKeyIsTheSharedHMACVector() {
    let key = Data((0..<32).map { UInt8($0) })
    XCTAssertEqual(UsernameDevice.claimKey(privateViewKey: key), Self.claimKey)
    let hex = (0..<32).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(UsernameDevice.keyBytes(hex: hex), key)
    XCTAssertEqual(UsernameDevice.keyBytes(hex: hex.uppercased()), key)
    XCTAssertNil(UsernameDevice.keyBytes(hex: String(hex.dropLast(2))))
    XCTAssertNil(UsernameDevice.keyBytes(hex: String(hex.dropLast()) + "g"))
    XCTAssertNil(UsernameDevice.claimKey(privateViewKey: key.dropLast()))
  }
  func testIosProofIsBase64URLOfTheTokenAndClaimKey() async throws {
    // These bytes give "+", "/" and "=" in standard base64.
    let token = Data([0xfb, 0xff, 0xbf, 0x00, 0x10])
    XCTAssertEqual(token.base64EncodedString(), "+/+/ABA=")
    let store = UsernameStore(persistence: UsernameMemory())
    let (_, devices) = await freshClaim(client(tokens: FakeDeviceTokens(token: token)), store)
    XCTAssertEqual(devices.count, 1)
    XCTAssertEqual(devices.first?["platform"] as? String, "ios")
    let proof = try XCTUnwrap(devices.first?["proof"] as? String)
    // The registry's strict decoder: the URL-safe alphabet, no padding.
    XCTAssertNil(proof.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    let json = try XCTUnwrap(Self.unbase64URL(proof))
    XCTAssertEqual(UsernameDevice.base64URL(json), proof)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])
    XCTAssertEqual(object, ["device_token": "+/+/ABA=", "claim_key": Self.claimKey])
    XCTAssertEqual(try UsernameDevice.iosProof(token: token, claimKey: Self.claimKey), proof)
  }
  func testRegistryCodesShowTheirMessages() async throws {
    let reserved = String(localized: "This username is reserved to protect users from scams.")
    let other = String(localized: "The username service couldn't complete the request. Please try again.")
    // (code, status, message, the saved claim is gone)
    let rows: [(String, Int, String, Bool)] = [
      ("geo.blocked", 403, UsernameFailure.regionBlocked.localizedDescription, true),
      ("device.invalid", 403, UsernameFailure.deviceUnsupported.localizedDescription, true),
      ("device.unsupported", 403, UsernameFailure.deviceUnsupported.localizedDescription, true),
      ("device.unavailable", 503, UsernameFailure.retry.localizedDescription, false),
      ("device.slot_used", 403, UsernameFailure.noFreeClaim.localizedDescription, true),
      ("name.unavailable", 409, UsernameFailure.unavailable.localizedDescription, true),
      ("handle.reserved", 403, reserved, false),
      ("handle.blocked", 403, reserved, false),
      ("rate.limited", 429, other, false),
    ]
    var claimKeys = Set<String>()
    for (code, status, message, cleared) in rows {
      let store = UsernameStore(persistence: UsernameMemory())
      let (result, devices) = await freshClaim(
        client(), store, reply: (status, ["error": ["code": code]]))
      XCTAssertEqual(failure(result), message, code)
      XCTAssertEqual(store.state.pending == nil, cleared, code)
      XCTAssertTrue(store.state.bindings.isEmpty, code)
      let proof = try XCTUnwrap(devices.first?["proof"] as? String, code)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(Self.unbase64URL(proof))) as? [String: String])
      claimKeys.insert(object["claim_key"] ?? "")
    }
    // The same wallet sends the same claim key on every attempt.
    XCTAssertEqual(claimKeys, [Self.claimKey])
    if Bundle.main.preferredLocalizations.first == "en" {
      XCTAssertEqual(
        UsernameFailure.regionBlocked.localizedDescription,
        "Username registration isn't available in your region.")
      XCTAssertEqual(UsernameFailure.deviceUnsupported.localizedDescription, "This phone can't claim a username.")
      XCTAssertEqual(
        UsernameFailure.retry.localizedDescription, "The claim could not be completed. Please try again.")
    }
  }
  func testPlatformErrorsShowTheirMessagesInARelease() async {
    // (tokens, message): a phone that can never make a token, or one that can on a retry.
    let rows: [(FakeDeviceTokens, String)] = [
      (FakeDeviceTokens(isSupported: false), UsernameFailure.deviceUnsupported.localizedDescription),
      (
        FakeDeviceTokens(error: DCError(.featureUnsupported)),
        UsernameFailure.deviceUnsupported.localizedDescription
      ),
      (FakeDeviceTokens(error: DCError(.unknownSystemFailure)), UsernameFailure.retry.localizedDescription),
      (FakeDeviceTokens(error: URLError(.notConnectedToInternet)), UsernameFailure.retry.localizedDescription),
      (FakeDeviceTokens(token: Data()), UsernameFailure.retry.localizedDescription),
    ]
    for (index, (tokens, message)) in rows.enumerated() {
      let store = UsernameStore(persistence: UsernameMemory())
      let (result, devices) = await freshClaim(client(tokens: tokens, allowDevProof: false), store)
      XCTAssertEqual(failure(result), message, "row \(index)")
      // No claim is sent, and none is saved to block another wallet.
      XCTAssertTrue(devices.isEmpty, "row \(index)")
      XCTAssertNil(store.state.pending, "row \(index)")
    }
  }
  func testDevProofOnlyInDebugBuilds() async throws {
    #if DEBUG
      XCTAssertTrue(UsernameDevice.allowsDevProof)
    #else
      XCTAssertFalse(UsernameDevice.allowsDevProof)
    #endif
    // A debug build on a simulator, or a phone without DeviceCheck: the dev proof.
    for tokens in [FakeDeviceTokens(isSupported: false), FakeDeviceTokens(error: DCError(.featureUnsupported))] {
      let store = UsernameStore(persistence: UsernameMemory())
      let (_, devices) = await freshClaim(client(tokens: tokens, allowDevProof: true), store)
      XCTAssertEqual(devices.count, 1)
      XCTAssertEqual(devices.first?["platform"] as? String, "dev")
      XCTAssertEqual(
        devices.first?["proof"] as? String, UsernameDevice.base64URL(Data(store.state.deviceID.utf8)))
    }
    // A phone that makes a token sends it, in a debug build too.
    let (_, real) = await freshClaim(
      client(tokens: FakeDeviceTokens(), allowDevProof: true), UsernameStore(persistence: UsernameMemory()))
    XCTAssertEqual(real.first?["platform"] as? String, "ios")
    // A transient error is never covered by the dev proof.
    let store = UsernameStore(persistence: UsernameMemory())
    let (result, none) = await freshClaim(
      client(tokens: FakeDeviceTokens(error: DCError(.unknownSystemFailure)), allowDevProof: true), store)
    XCTAssertEqual(failure(result), UsernameFailure.retry.localizedDescription)
    XCTAssertTrue(none.isEmpty)
  }
  func testDebugURLIsThisMachineATailscaleHTTPSNameOrStaging() {
    for raw in ["http://localhost:8787", "https://localhost:8787", "https://mac.example-tailnet.ts.net",
      "https://Mac.Example-Tailnet.TS.NET/oah", "https://staging-registry.monero.one",
      "https://staging-mirror.monero.one/oah/v1/"]
    {
      XCTAssertTrue(UsernameConfiguration.isDebugURL(URL(string: raw)!), raw)
    }
    for raw in [
      "http://mac.example-tailnet.ts.net", "https://ts.net", "https://.ts.net", "https://x.ts.net.example.com",
      "https://example.com", "https://xts.net", "ftp://localhost", "https://user@mac.example-tailnet.ts.net",
      "https://user:secret@mac.example-tailnet.ts.net", "http://user@localhost:8787",
      "https://mac.example-tailnet.ts.net?debug=1", "https://mac.example-tailnet.ts.net#top",
      "http://localhost:8787?debug=1", "http://staging-registry.monero.one", "https://registry.monero.one",
      "https://mirror.monero.one", "https://staging-registry.monero.one.example.com",
      "https://user@staging-registry.monero.one",
    ] {
      XCTAssertFalse(UsernameConfiguration.isDebugURL(URL(string: raw)!), raw)
    }
  }
  func testReleaseURLIsOnlyTheProductionRegistryOrMirrorOverHTTPS() {
    for raw in ["https://registry.monero.one", "https://mirror.monero.one/oah/v1/", "https://Registry.Monero.One"] {
      XCTAssertTrue(UsernameConfiguration.allows(URL(string: raw)!, debug: false), raw)
    }
    for raw in [
      "http://registry.monero.one", "https://registry.monero.one:8443", "https://staging-registry.monero.one",
      "https://staging-mirror.monero.one/oah/v1/", "http://localhost:8787", "https://localhost:8787",
      "https://mac.example-tailnet.ts.net", "https://registry.monero.one.example.com", "https://monero.one",
      "https://user@registry.monero.one", "https://registry.monero.one?debug=1", "https://registry.monero.one#x",
    ] {
      XCTAssertFalse(UsernameConfiguration.allows(URL(string: raw)!, debug: false), raw)
    }
    XCTAssertFalse(UsernameConfiguration.allows(URL(string: "https://registry.monero.one")!, debug: true))
    XCTAssertFalse(UsernameConfiguration.allows(URL(string: "https://staging-registry.monero.one:444")!, debug: true))
  }
  func testReleaseBuildValuesAreProductionAndMakeAWorkingConfiguration() throws {
    let values = UsernameEnvironment.production
    let configuration = try XCTUnwrap(UsernameResolutionConfiguration.make(values, debug: false))
    XCTAssertEqual(configuration.registry.url.absoluteString, "https://registry.monero.one")
    XCTAssertEqual(configuration.mirror.absoluteString, "https://mirror.monero.one/oah/v1/")
    XCTAssertEqual(configuration.genesisRoot, "37c80669fb410913857b678d9aea9a54c5344fe152c0fb247549040d05477f26")
    XCTAssertEqual(
      configuration.registry.registrarKey, "40f69d3b401370c38c6f0b62976a688fd44b56abe22be66168b1f9a44822a988")
    XCTAssertEqual(
      configuration.registry.rulesHash, "b775ea7a655fd01c57820f09d08a421e51b0739240fbd940f399e65bd6fcdeac")
    XCTAssertEqual(configuration.registry.termsVersion, "terms-pending-v1")
    XCTAssertEqual(configuration.origin, "monero.one/oah")
    // A debug build never reaches production, and a release build never reaches staging.
    XCTAssertNil(UsernameConfiguration.make(values, debug: true))
    XCTAssertNil(UsernameResolutionConfiguration.make(.staging, debug: false))
  }
  func testDebugBuildDefaultsToStagingAndTheLaunchEnvironmentOverridesEachValue() throws {
    let staging = try XCTUnwrap(UsernameResolutionConfiguration.make(.staging, debug: true))
    XCTAssertEqual(staging.registry.url.absoluteString, "https://staging-registry.monero.one")
    XCTAssertEqual(staging.mirror.absoluteString, "https://staging-mirror.monero.one/oah/v1/")
    XCTAssertEqual(staging.genesisRoot, "f0f5024f667e6957ce56d0a746a358b5bae36f7772dd56a0dd489a66a85e815e")
    XCTAssertEqual(staging.registry.termsVersion, "local-development-v1")
    XCTAssertEqual(UsernameEnvironment.staging.overridden(by: [:]), .staging)

    let local = UsernameEnvironment.staging.overridden(by: [
      "USERNAME_REGISTRY_URL": "http://localhost:8787", "USERNAME_MIRROR_URL": "http://localhost:8788/oah/v1/",
      "USERNAME_GENESIS_ROOT": String(repeating: "1", count: 64),
      "USERNAME_REGISTRAR_KEY": String(repeating: "2", count: 64),
      "USERNAME_RULES_HASH": String(repeating: "3", count: 64), "USERNAME_TERMS_VERSION": "local-test-v2",
    ])
    let configuration = try XCTUnwrap(UsernameResolutionConfiguration.make(local, debug: true))
    XCTAssertEqual(configuration.registry.url.absoluteString, "http://localhost:8787")
    XCTAssertEqual(configuration.mirror.absoluteString, "http://localhost:8788/oah/v1/")
    XCTAssertEqual(configuration.genesisRoot, String(repeating: "1", count: 64))
    XCTAssertEqual(configuration.registry.registrarKey, String(repeating: "2", count: 64))
    XCTAssertEqual(configuration.registry.rulesHash, String(repeating: "3", count: 64))
    XCTAssertEqual(configuration.registry.termsVersion, "local-test-v2")
    // A local registry still cannot reach a release build.
    XCTAssertNil(UsernameConfiguration.make(local, debug: false))

    let one = UsernameEnvironment.staging.overridden(by: ["USERNAME_REGISTRY_URL": "https://mac.example.ts.net"])
    XCTAssertEqual(one.registryURL, "https://mac.example.ts.net")
    XCTAssertEqual(one.mirrorURL, UsernameEnvironment.staging.mirrorURL)
  }
  func testConfigurationRefusesBadValues() {
    var values = UsernameEnvironment.staging
    XCTAssertNotNil(UsernameResolutionConfiguration.make(values, debug: true))
    for change: (inout UsernameEnvironment) -> Void in [
      { $0.registrarKey = String(repeating: "A", count: 64) }, { $0.rulesHash = String(repeating: "b", count: 63) },
      { $0.genesisRoot = String(repeating: "g", count: 64) }, { $0.termsVersion = "" },
      { $0.termsVersion = "terms pending" }, { $0.termsVersion = String(repeating: "t", count: 65) },
      { $0.registryURL = "" }, { $0.mirrorURL = "https://example.com/oah/v1/" },
      { $0.mirrorURL = $0.registryURL },
    ] {
      values = .staging
      change(&values)
      XCTAssertNil(UsernameResolutionConfiguration.make(values, debug: true))
    }
  }
  func testTestResetClearsTheSavedStateAndCanKeepTheDeviceID() throws {
    let memory = UsernameMemory()
    let store = UsernameStore(persistence: memory)
    try store.savePending(pending())
    let deviceID = memory.state.deviceID
    memory.state.bindings = [binding()]
    memory.state.nextFreeClaim = .distantFuture

    UsernameStore.applyTestReset(nil, to: memory)
    UsernameStore.applyTestReset("0", to: memory)
    XCTAssertEqual(memory.state.bindings.count, 1)

    UsernameStore.applyTestReset("keep-device", to: memory)
    XCTAssertTrue(memory.state.bindings.isEmpty)
    XCTAssertNil(memory.state.pending)
    XCTAssertNil(memory.state.nextFreeClaim)
    XCTAssertEqual(memory.state.deviceID, deviceID)

    memory.state.bindings = [binding()]
    UsernameStore.applyTestReset("1", to: memory)
    XCTAssertTrue(memory.state.bindings.isEmpty)
    XCTAssertNotEqual(memory.state.deviceID, deviceID)
  }
}

private struct FakeDeviceTokens: UsernameDeviceTokens {
  var isSupported = true
  var token = Data([0x01, 0x02, 0x03])
  var error: Error?
  func generateToken() async throws -> Data {
    if let error { throw error }
    return token
  }
}

private final class UsernameMemory: UsernamePersistence {
  var state = UsernameLocalState()
  var failWrites = false
  func read() throws -> UsernameLocalState { state }
  func write(_ state: UsernameLocalState) throws {
    if failWrites { throw UsernameFailure.storage }
    self.state = state
  }
}
private final class UsernameURLProtocol: URLProtocol {
  /// A body is a JSON object, or raw bytes (the rules text).
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
      client?.urlProtocol(
        self, didLoad: try (body as? Data) ?? JSONSerialization.data(withJSONObject: body))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
