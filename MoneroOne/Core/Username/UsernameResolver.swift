import CryptoKit
import Foundation
import MoneroKit
import OAHCore
import Security

enum UsernameTrust: String, Codable {
  case published, pending, stale, expired
  /// Every record that is not checked against a fresh public log gets the
  /// same limit: stale (6 to 48 h), expired (over 48 h) and pending.
  var amountLimit: Decimal? { self == .published ? nil : Decimal(string: "0.1") }
  /// Why the limit applies. Amount and Send show it.
  var limitMessage: String? {
    switch self {
    case .published: return nil
    case .pending:
      return String(
        localized: "This username is not in the public log yet. The payment limit is 0.1 XMR.")
    case .stale, .expired:
      return String(localized: "Username records are out of date. The payment limit is 0.1 XMR.")
    }
  }
  var text: String {
    switch self {
    case .published: return String(localized: "Signature checked")
    case .pending: return String(localized: "Not yet in the public log")
    case .stale: return String(localized: "Username records are out of date")
    case .expired: return String(localized: "Using a previously checked username")
    }
  }
}

/// The username check Send runs just before it broadcasts.
enum UsernameSendRecheck {
  /// The message that stops the payment, or nil to send it. Only a new
  /// address stops it. A new trust level alone does not: its amount limit
  /// applies to this payment. `sentAmount` is what the payment really sends
  /// (for send all, the review's sweep amount); nil when it is not known.
  static func failure(
    reviewedAddress: String, sentAmount: Decimal?,
    result: Result<OpenAliasResult, OpenAliasFailure>
  ) -> String? {
    switch result {
    case .failure(let error): return error.message
    case .success(let checked):
      if checked.address != reviewedAddress {
        return String(
          localized: "The username changed since your review. Look it up again before sending.")
      }
      if let trust = checked.usernameTrust, let limit = trust.amountLimit,
        (sentAmount ?? .greatestFiniteMagnitude) > limit
      {
        return trust.limitMessage
      }
      return nil
    }
  }
}

enum UsernameRecipient {
  /// Classification is local and deliberately checks syntax only. The shared
  /// core checks the frozen rules and signatures when a lookup completes.
  /// A username is one label (`@joe`, `joe@monero.one`): the `@` form never
  /// takes a dot, so `@getmonero.org` is not a username.
  static func localPart(_ raw: String) -> String? {
    let lower = raw.lowercased()
    let local: String
    if lower.hasPrefix("@") {
      local = String(lower.dropFirst())
    } else if lower.hasSuffix("@monero.one") {
      local = String(lower.dropLast(11))
    } else if lower.hasSuffix(".monero.one") {
      local = String(lower.dropLast(11))
    } else {
      return nil
    }
    guard local.utf8.count >= 3, local.utf8.count <= 15, !local.contains("__"),
      local.first.map({ $0 >= "a" && $0 <= "z" }) == true,
      local.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
    else { return nil }
    return local
  }
}

struct UsernameResolutionConfiguration {
  let registry: UsernameConfiguration
  let mirror: URL
  let genesisRoot: String
  var origin = "monero.one/oah"
  static var current: Self? {
    #if DEBUG
      let env = ProcessInfo.processInfo.environment
      guard let registry = UsernameConfiguration.current,
        let raw = env["USERNAME_MIRROR_URL"], let mirror = URL(string: raw),
        UsernameConfiguration.isDebugURL(mirror),
        mirror != registry.url,
        let root = env["USERNAME_GENESIS_ROOT"], root.count == 64,
        root.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { return nil }
      return Self(registry: registry, mirror: mirror, genesisRoot: root)
    #else
      return nil
    #endif
  }
}

/// Every saved receipt contains the signed records and signed mirror evidence.
/// No eviction: forgetting a genesis would silently restore first-contact trust.
protocol UsernameResolutionPersistence {
  func read(_ name: String) throws -> [String: Any]?
  func write(_ value: [String: Any], name: String) throws
}

struct UsernameResolutionStore: UsernameResolutionPersistence {
  let service: String
  init(configuration: UsernameResolutionConfiguration, network: String) {
    let scope =
      configuration.registry.url.absoluteString + configuration.registry.registrarKey
      + configuration.genesisRoot + network
    service =
      "one.monero.MoneroOne.username-receipts.v1."
      + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func query(_ name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
  }
  func read(_ name: String) throws -> [String: Any]? {
    var q = query(name)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw UsernameFailure.storage }
    return value
  }
  func write(_ value: [String: Any], name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    let q = query(name)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw UsernameFailure.storage }
    var item = q
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw UsernameFailure.storage
    }
  }
}

@MainActor
final class UsernameResolver {
  private let configuration: UsernameResolutionConfiguration
  private let session: URLSession
  private let network: String
  private let store: UsernameResolutionPersistence
  private let now: () -> Date
  private let ownedGenesis: @MainActor (String, String) throws -> String?
  init(
    configuration: UsernameResolutionConfiguration, network: String, session: URLSession,
    store: UsernameResolutionPersistence? = nil, now: @escaping () -> Date = Date.init,
    ownedGenesis: @escaping @MainActor (String, String) throws -> String? = { handle, network in
      let own = UsernameStore.shared
      guard !own.storageError else { throw UsernameFailure.storage }
      return own.state.bindings.first { $0.handle == handle && $0.network == network }?.genesisHash
    }
  ) {
    self.configuration = configuration
    self.network = network
    self.session = session
    self.store = store ?? UsernameResolutionStore(configuration: configuration, network: network)
    self.now = now
    self.ownedGenesis = ownedGenesis
  }

  private func fetch(_ base: URL, _ path: String) async throws -> Data {
    var request = URLRequest(
      url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("application/json, application/octet-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw OpenAliasFailure.network }
    if http.statusCode == 404 || http.statusCode == 451 {
      throw OpenAliasFailure.usernameUnavailable
    }
    guard http.statusCode == 200 else { throw OpenAliasFailure.network }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 4_194_304 else { throw OpenAliasFailure.usernameVerification }
      data.append(byte)
    }
    return data
  }
  private func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenAliasFailure.usernameVerification
    }
    return result
  }
  private func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }

  func resolve(_ name: OpenAliasName) async throws -> OpenAliasResult {
    guard let local = UsernameRecipient.localPart(name.query) else {
      throw OpenAliasFailure.usernameVerification
    }
    let parsed = try OAHCore.call(["op": "parse_recipient", "input": "@" + local])
    guard let handle = parsed["handle"] as? String, let bucket = parsed["bucket"] as? Int,
      let canonical = parsed["name"] as? String
    else { throw OpenAliasFailure.usernameVerification }
    let api = configuration.registry.url
    let mirror = configuration.mirror
    // Always ask the operator before showing a username (including a hold).
    let head = try object(await fetch(api, "v1/handles/" + handle))
    guard let rows = head["records"] as? [[String: Any]], !rows.isEmpty, rows.count <= 4096 else {
      throw OpenAliasFailure.usernameVerification
    }
    let records = try rows.map { row -> String in
      guard let value = row["record"] as? String else {
        throw OpenAliasFailure.usernameVerification
      }
      return value
    }
    let rules = try await fetch(api, "v1/rules")
    let latestData = try await fetch(mirror, "snapshots/latest")
    guard let latest = String(data: latestData, encoding: .utf8),
      let epoch = UInt64(latest), String(epoch) == latest
    else { throw OpenAliasFailure.usernameVerification }
    let manifest = try object(await fetch(mirror, "epochs/\(epoch)/manifest.json"))
    let genesis = try await fetch(mirror, "epochs/0/epoch")
    let signedBucket = try await fetch(mirror, "snapshots/\(epoch)/buckets/\(bucket)")
    guard signedBucket.count >= 64, let epochEncoding = manifest["encoding"] as? String,
      let checkpoint = manifest["checkpoint"] as? String,
      let time = manifest["published_at"] as? NSNumber,
      let signature = manifest["publication_signature"] as? String,
      let rulesText = String(data: rules, encoding: .utf8)
    else { throw OpenAliasFailure.usernameVerification }
    try Task.checkCancellation()
    var request: [String: Any] = [
      "name": canonical, "records": records, "network": network,
      "registrar_key": configuration.registry.registrarKey, "rules": rulesText,
      "rules_hash": configuration.registry.rulesHash, "genesis_epoch": b64(genesis),
      "genesis_epoch_root": configuration.genesisRoot, "origin": configuration.origin,
      "now": Int(now().timeIntervalSince1970),
      "snapshot": [
        "epoch": epochEncoding, "checkpoint": checkpoint,
        "bucket": b64(signedBucket.dropLast(64)), "signature": b64(signedBucket.suffix(64)),
        "published_at": time, "publication_signature": signature,
      ],
    ]
    request["owned_genesis_hash"] = try ownedGenesis(handle, network)
    let result = try await UsernameResolutionWorker.verify(
      request, store: store, handle: handle, canonical: canonical)
    guard let address = result["address"] as? String, let age = result["snapshot_age"] as? Int,
      let published = result["published"] as? Bool
    else { throw OpenAliasFailure.usernameVerification }
    let trust: UsernameTrust =
      age > 48 * 3600 ? .expired : age >= 6 * 3600 ? .stale : published ? .published : .pending
    return OpenAliasResult(address: address, recipientName: nil, dnssec: .off, usernameTrust: trust)
  }
}

/// All pin reads, expensive signature checks and atomic receipt writes use one
/// background queue. A long valid chain cannot freeze typing, and two lookups
/// cannot both verify against an old pin then overwrite each other's receipts.
private enum UsernameResolutionWorker {
  private static let queue = DispatchQueue(
    label: "one.monero.username-verification", qos: .userInitiated)
  static func verify(
    _ input: [String: Any], store: UsernameResolutionPersistence,
    handle: String, canonical: String
  ) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          var request = input
          let previous = try store.read(handle)
          var recipients = previous?["recipients"] as? [String] ?? []
          request["known_recipient"] = recipients.contains(canonical)
          if let previous {
            guard let result = previous["result"] as? [String: Any], let pin = result["pin"],
              let epoch = result["epoch"]
            else { throw UsernameFailure.storage }
            request["pin"] = pin
            request["previous_epoch"] = epoch
          }
          let result = try OAHCore.call(["op": "verify_resolution", "request": request])
          if !recipients.contains(canonical) { recipients.append(canonical) }
          try store.write(
            ["request": request, "result": result, "recipients": recipients], name: handle)
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
