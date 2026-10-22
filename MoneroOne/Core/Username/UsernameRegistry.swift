import Foundation
import OAHCore

enum UsernameFailure: Error, LocalizedError {
  case storage, walletChanged, unavailable, noFreeClaim, notConfigured, verification, pendingClaim
  case server(String)
  var errorDescription: String? {
    switch self {
    case .storage: return String(localized: "Your username could not be saved securely. Unlock the app and try again.")
    case .walletChanged:
      return String(localized: "The wallet changed. Open this flow from the wallet you want to use.")
    case .unavailable: return String(localized: "This username is unavailable.")
    case .noFreeClaim: return String(localized: "A free username isn't available on this phone.")
    case .notConfigured: return String(localized: "Username registration isn't available yet.")
    case .verification: return String(localized: "The username response could not be verified. Please try again.")
    case .pendingClaim:
      return String(localized: "Finish checking the previous claim before choosing another username.")
    case .server(let message): return message
    }
  }
}

struct UsernameConfiguration {
  let url: URL
  let registrarKey: String
  let rulesHash: String
  /// The registry has no real device verifier yet. This explicit local
  /// development configuration cannot enable public claims in a release.
  static var current: UsernameConfiguration? {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      guard let raw = env["USERNAME_REGISTRY_URL"], let url = URL(string: raw),
        url.host == "localhost", ["http", "https"].contains(url.scheme ?? ""),
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        let key = env["USERNAME_REGISTRAR_KEY"], key.count == 64,
        let rules = env["USERNAME_RULES_HASH"], rules.count == 64
      else { return nil }
      return UsernameConfiguration(url: url, registrarKey: key, rulesHash: rules)
    #else
      return nil
    #endif
  }
}

enum UsernameRules {
  static func normalize(_ input: String) throws -> String {
    let value = try OAHCore.call(["op": "validate", "handle": input])
    guard let handle = value["handle"] as? String else { throw UsernameFailure.verification }
    return handle
  }
  static func message(for error: Error) -> String {
    guard let code = (error as? OAHError)?.code else { return error.localizedDescription }
    switch code {
    case "handle.too_short": return String(localized: "Use at least 3 characters.")
    case "handle.too_long": return String(localized: "Use no more than 15 characters.")
    case "handle.first_not_letter": return String(localized: "Start with a letter.")
    case "handle.double_underscore": return String(localized: "Use only one _ in a row.")
    case "handle.blocked": return String(localized: "This username is reserved to protect users from scams.")
    default: return String(localized: "Use only a–z, 0–9 and _.")
    }
  }
}

final class UsernameSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

@MainActor
final class UsernameRegistry {
  private let configuration: UsernameConfiguration
  private let session: URLSession
  init(configuration: UsernameConfiguration, session: URLSession? = nil) {
    self.configuration = configuration
    let options = URLSessionConfiguration.ephemeral
    options.timeoutIntervalForRequest = 20
    options.timeoutIntervalForResource = 25
    options.urlCache = nil
    self.session =
      session
      ?? URLSession(configuration: options, delegate: UsernameSessionDelegate(), delegateQueue: nil)
  }

  private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
    let url = configuration.url.appendingPathComponent("v1").appendingPathComponent(path)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else {
      throw UsernameFailure.verification
    }
    guard (200..<300).contains(response.statusCode) else {
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let code = (object?["error"] as? [String: Any])?["code"] as? String ?? ""
      if code == "handle.not_found" { throw RegistryNotFound() }
      if code == "device.slot_used" { throw UsernameFailure.noFreeClaim }
      if code == "name.unavailable" { throw UsernameFailure.unavailable }
      if code == "handle.reserved" || code == "handle.blocked" {
        throw UsernameFailure.server(String(localized: "This username is reserved to protect users from scams."))
      }
      if code == "nonce.invalid" { throw ExpiredClaim() }
      throw UsernameFailure.server(
        String(localized: "The username service couldn't complete the request. Please try again."))
    }
    return data
  }
  private struct RegistryNotFound: Error {}
  private struct ExpiredClaim: Error {}
  private func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw UsernameFailure.verification
    }
    return value
  }

  /// Called only after the user agrees to claim. No preflight runs on Home
  /// or Welcome, and no spend key leaves the wallet's existing signer.
  func claim(
    displayHandle: String, walletKey: String, network: String, store: UsernameStore,
    makeSubaddress: () async throws -> String,
    sign: (String, String) throws -> String,
    isCurrentWallet: () -> Bool
  ) async throws -> UsernameBinding {
    guard isCurrentWallet(), !walletKey.isEmpty else { throw UsernameFailure.walletChanged }
    guard !store.storageError else { throw UsernameFailure.storage }
    try store.beginClaim()
    defer { store.endClaim() }
    let handle = try UsernameRules.normalize(displayHandle)
    // This wallet's claim for this name, cleared because the name was free.
    var released: PendingUsernameClaim?
    if let pending = store.state.pending {
      let same = pending.walletKey == walletKey && pending.network == network && pending.handle == handle
      let admitted: UsernameBinding?
      do {
        admitted = try await recheck(pending, store: store)
      } catch {
        // The result is still unknown: the saved claim stays and blocks
        // other names until a later check finds it.
        if same { throw error }
        throw UsernameFailure.pendingClaim
      }
      if let admitted {
        if same { return admitted }
        // The earlier claim went through and used this phone's free claim.
        throw UsernameFailure.noFreeClaim
      }
      // The name is free or another owner holds it. The saved claim is gone,
      // and a new claim starts here (a taken name stops at the check below).
      if same { released = pending }
    }
    guard isCurrentWallet(), !store.storageError else { throw UsernameFailure.walletChanged }
    let info = try object(await request("info"))
    guard info["registrar_key"] as? String == configuration.registrarKey,
      info["rules_hash"] as? String == configuration.rulesHash,
      info["network"] as? String == network, info["zone"] as? String == "monero.one",
      info["open"] as? Bool == true
    else { throw UsernameFailure.verification }
    let rulesData = try await request("rules")
    guard let rules = String(data: rulesData, encoding: .utf8), isCurrentWallet() else {
      throw UsernameFailure.walletChanged
    }
    do {
      let existing = try object(await request("handles/" + handle))
      // The earlier signed request landed after the check above: it is this
      // wallet's name, with no new signature.
      if let released, let rows = existing["records"] as? [[String: Any]], rows.count == 1,
        let record = rows.first?["record"] as? String,
        let binding = try? accept(record, pending: released, store: store)
      {
        return binding
      }
      throw UsernameFailure.unavailable
    } catch is RegistryNotFound {}
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    let subaddress = try await makeSubaddress()
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    let nonceReply = try object(
      await request("nonce", body: ["handle": handle, "subaddress": subaddress]))
    guard let nonce = nonceReply["nonce"] as? String, isCurrentWallet() else {
      throw UsernameFailure.walletChanged
    }
    let unsigned = try OAHCore.call([
      "op": "prepare_claim", "handle": handle, "subaddress": subaddress,
      "nonce": nonce, "network": network, "rules": rules, "rules_hash": configuration.rulesHash,
    ])
    guard let bytes = unsigned["record"] as? String, let hash = unsigned["record_hash"] as? String,
      let message = unsigned["signing_message"] as? String
    else { throw UsernameFailure.verification }
    let signature = try sign(message, subaddress)
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    let pending = PendingUsernameClaim(
      walletKey: walletKey, network: network, handle: handle,
      displayHandle: displayHandle, subaddress: subaddress, nonce: nonce, unsignedRecord: bytes,
      recordHash: hash, ownerSignature: signature, registrarKey: configuration.registrarKey,
      rules: rules, rulesHash: configuration.rulesHash)
    // Persist before POST: if the reply is lost, check this exact signed
    // genesis on the next attempt instead of consuming another claim.
    try store.savePending(pending)
    return try await submit(pending, store: store)
  }

  /// Checks a claim saved before its POST. Returns the binding when the name
  /// points to the claim's wallet, and nil after it clears the claim (the
  /// name is free, or another owner holds it). Throws, and keeps the claim,
  /// while the registry cannot answer or its answer does not verify.
  private func recheck(_ pending: PendingUsernameClaim, store: UsernameStore) async throws
    -> UsernameBinding?
  {
    // A claim signed for another registry can never finish against this one.
    guard pending.registrarKey == configuration.registrarKey,
      pending.rulesHash == configuration.rulesHash
    else {
      try store.savePending(nil)
      return nil
    }
    let records: [[String: Any]]
    do {
      let existing = try object(await request("handles/" + pending.handle))
      guard let rows = existing["records"] as? [[String: Any]], !rows.isEmpty else {
        throw UsernameFailure.verification
      }
      records = rows
    } catch is RegistryNotFound {
      try store.savePending(nil)
      return nil
    }
    guard let genesis = records.first?["record"] as? String else {
      throw UsernameFailure.verification
    }
    if Self.isOtherGenesis(genesis, pending: pending) {
      try store.savePending(nil)
      return nil
    }
    guard records.count == 1 else { throw UsernameFailure.verification }
    return try accept(genesis, pending: pending, store: store)
  }

  /// True when the name's first record is a different genesis than the one
  /// this phone signed: another owner holds the name. A record with this
  /// genesis but a bad signature is not proof of that.
  private static func isOtherGenesis(_ record: String, pending: PendingUsernameClaim) -> Bool {
    do {
      _ = try OAHCore.call(claimCheck(record, pending: pending))
      return false
    } catch let error as OAHError {
      return error.code == "mobile.claim_mismatch"
    } catch { return false }
  }

  private static func claimCheck(_ record: String, pending: PendingUsernameClaim) -> [String: Any] {
    [
      "op": "verify_claim", "record": record,
      "expected_record_hash": pending.recordHash, "handle": pending.handle,
      "subaddress": pending.subaddress,
      "network": pending.network, "registrar_key": pending.registrarKey, "rules": pending.rules,
      "rules_hash": pending.rulesHash,
    ]
  }

  private func submit(_ pending: PendingUsernameClaim, store: UsernameStore) async throws
    -> UsernameBinding
  {
    guard pending.registrarKey == configuration.registrarKey,
      pending.rulesHash == configuration.rulesHash
    else {
      throw UsernameFailure.verification
    }
    #if DEBUG
      let proof = Data(store.state.deviceID.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      do {
        let response = try object(
          await request(
            "claims",
            body: [
              "nonce": pending.nonce,
              "record": pending.unsignedRecord, "owner_signature": pending.ownerSignature,
              "device": ["platform": "dev", "proof": proof],
              "terms_version": "local-development-v1",
            ]))
        guard response["handle"] as? String == pending.handle,
          let record = response["record"] as? String
        else {
          throw UsernameFailure.verification
        }
        return try accept(record, pending: pending, store: store)
      } catch is ExpiredClaim {
        try store.savePending(nil)
        throw UsernameFailure.server(String(localized: "The request expired. Please claim again."))
      } catch let error as UsernameFailure {
        switch error {
        case .noFreeClaim, .unavailable: try store.savePending(nil)
        default: break
        }
        throw error
      }
    #else
      throw UsernameFailure.notConfigured
    #endif
  }

  private func accept(_ record: String, pending: PendingUsernameClaim, store: UsernameStore) throws
    -> UsernameBinding
  {
    do {
      _ = try OAHCore.call(Self.claimCheck(record, pending: pending))
    } catch { throw UsernameFailure.verification }
    let binding = UsernameBinding(
      walletKey: pending.walletKey, network: pending.network,
      handle: pending.handle, displayHandle: pending.displayHandle, subaddress: pending.subaddress,
      genesisHash: pending.recordHash, record: record, claimedAt: Date())
    try store.accept(binding)
    return binding
  }
}
