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
  private func client() -> UsernameRegistry {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UsernameURLProtocol.self]
    return UsernameRegistry(
      configuration: UsernameConfiguration(
        url: URL(string: "http://localhost:8787")!, registrarKey: f["key"]!,
        rulesHash: f["rulesHash"]!), session: URLSession(configuration: config))
  }
  private func claim(
    _ client: UsernameRegistry, _ store: UsernameStore, handle: String = "Alice",
    wallet: String = "wallet-A", current: @escaping () -> Bool = { true }
  ) async throws -> UsernameBinding {
    try await client.claim(
      displayHandle: handle, walletKey: wallet, network: "mainnet", store: store,
      makeSubaddress: {
        XCTFail("Recovery must not allocate a new subaddress")
        throw UsernameFailure.verification
      },
      sign: { _, _ in
        XCTFail("Recovery must not sign another claim")
        throw UsernameFailure.verification
      }, isCurrentWallet: current)
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
    UsernameURLProtocol.handler = { [info, f] request in
      switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
      case ("GET", "/v1/handles/alice"): return (404, ["error": ["code": "handle.not_found"]])
      case ("GET", "/v1/info"): return (200, info)
      case ("GET", "/v1/rules"): return (200, Data(f["rules"]!.utf8))
      case ("POST", "/v1/nonce"): return (200, ["nonce": nonce])
      case ("POST", "/v1/claims"):
        claimNonce = UsernameURLProtocol.body(request)["nonce"] as? String
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
        }, isCurrentWallet: { true })
      XCTFail("Expected unavailable")
    } catch {
      XCTAssertEqual(failure(error), UsernameFailure.unavailable.localizedDescription)
    }
    XCTAssertEqual(made, 1)
    XCTAssertEqual(signed, 1)
    XCTAssertEqual(claimNonce, nonce)
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
