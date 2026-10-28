import CryptoKit
import DeviceCheck
import Foundation
import OAHCore

enum UsernameFailure: Error, LocalizedError {
  case storage, walletChanged, walletOpening, unavailable, noFreeClaim, notConfigured, verification
  case pendingClaim, regionBlocked, deviceUnsupported, retry
  case server(String)
  var errorDescription: String? {
    switch self {
    case .storage: return String(localized: "Your username could not be saved securely. Unlock the app and try again.")
    case .walletChanged:
      return String(localized: "The wallet changed. Open this flow from the wallet you want to use.")
    case .walletOpening: return String(localized: "Your wallet is still opening. Try again in a moment.")
    case .unavailable: return String(localized: "This username is unavailable.")
    case .noFreeClaim: return String(localized: "A free username isn't available on this phone.")
    case .notConfigured: return String(localized: "Username registration isn't available yet.")
    case .verification: return String(localized: "The username response could not be verified. Please try again.")
    case .pendingClaim:
      return String(localized: "Finish checking the previous claim before choosing another username.")
    case .regionBlocked: return String(localized: "Username registration isn't available in your region.")
    case .deviceUnsupported: return String(localized: "This phone can't claim a username.")
    case .retry: return String(localized: "The claim could not be completed. Please try again.")
    case .server(let message): return message
    }
  }
}

/// The public values of one registry and its mirror (no secrets). Release
/// builds use `production`; debug builds use `staging` unless the launch
/// environment overrides a value (`USERNAME_*`, for a local registry).
struct UsernameEnvironment: Equatable {
  var registryURL: String
  var mirrorURL: String
  var genesisRoot: String
  var registrarKey: String
  var rulesHash: String
  var termsVersion: String
  var origin = "monero.one/oah"

  static let production = UsernameEnvironment(
    registryURL: "https://registry.monero.one",
    mirrorURL: "https://mirror.monero.one/oah/v1/",
    genesisRoot: "37c80669fb410913857b678d9aea9a54c5344fe152c0fb247549040d05477f26",
    registrarKey: "40f69d3b401370c38c6f0b62976a688fd44b56abe22be66168b1f9a44822a988",
    rulesHash: "b775ea7a655fd01c57820f09d08a421e51b0739240fbd940f399e65bd6fcdeac",
    // Placeholder until the terms text exists. Replace it before a release ships.
    termsVersion: "terms-pending-v1")

  static let staging = UsernameEnvironment(
    registryURL: "https://staging-registry.monero.one",
    mirrorURL: "https://staging-mirror.monero.one/oah/v1/",
    genesisRoot: "f0f5024f667e6957ce56d0a746a358b5bae36f7772dd56a0dd489a66a85e815e",
    registrarKey: "809d48344049bab6e37503094af5b3a947184ee0be45b304305d7c916d1588e2",
    rulesHash: "b775ea7a655fd01c57820f09d08a421e51b0739240fbd940f399e65bd6fcdeac",
    termsVersion: "local-development-v1")

  /// This build's values. Release builds ignore the launch environment.
  static var build: UsernameEnvironment {
    #if DEBUG
      staging.overridden(by: ProcessInfo.processInfo.environment)
    #else
      production
    #endif
  }

  /// Each `USERNAME_*` variable that is set replaces its one value.
  func overridden(by env: [String: String]) -> UsernameEnvironment {
    var values = self
    if let value = env["USERNAME_REGISTRY_URL"] { values.registryURL = value }
    if let value = env["USERNAME_MIRROR_URL"] { values.mirrorURL = value }
    if let value = env["USERNAME_GENESIS_ROOT"] { values.genesisRoot = value }
    if let value = env["USERNAME_REGISTRAR_KEY"] { values.registrarKey = value }
    if let value = env["USERNAME_RULES_HASH"] { values.rulesHash = value }
    if let value = env["USERNAME_TERMS_VERSION"] { values.termsVersion = value }
    return values
  }

  static func isHex64(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

struct UsernameConfiguration {
  let url: URL
  let registrarKey: String
  let rulesHash: String
  /// Sent as `terms_version` with each claim.
  let termsVersion: String

  #if DEBUG
    static let isDebugBuild = true
  #else
    static let isDebugBuild = false
  #endif

  /// The registry this build talks to, or nil when a value is not valid.
  static var current: UsernameConfiguration? { make(UsernameEnvironment.build, debug: isDebugBuild) }

  static func make(_ values: UsernameEnvironment, debug: Bool) -> UsernameConfiguration? {
    guard let url = URL(string: values.registryURL), allows(url, debug: debug),
      UsernameEnvironment.isHex64(values.registrarKey), UsernameEnvironment.isHex64(values.rulesHash),
      (1...64).contains(values.termsVersion.utf8.count),
      values.termsVersion.utf8.allSatisfy({ (33...126).contains($0) })
    else { return nil }
    return UsernameConfiguration(
      url: url, registrarKey: values.registrarKey, rulesHash: values.rulesHash, termsVersion: values.termsVersion)
  }

  /// Release builds reach only the production registry and mirror over
  /// HTTPS. Debug builds reach only the hosts in `isDebugURL`, never production.
  static func allows(_ url: URL, debug: Bool) -> Bool {
    if debug { return isDebugURL(url) }
    guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil,
      url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
    else { return false }
    return productionHosts.contains(host)
  }

  /// Debug builds talk to a registry on this machine, to one on the developer's
  /// private Tailscale network over HTTPS, for tests on a real phone, or to the
  /// staging registry and its mirror.
  static func isDebugURL(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let scheme = url.scheme?.lowercased(), let host = url.host
    else { return false }
    if host == "localhost" { return ["http", "https"].contains(scheme) }
    if stagingHosts.contains(host.lowercased()) { return scheme == "https" && url.port == nil }
    let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
    return scheme == "https" && labels.count >= 3 && labels.suffix(2) == ["ts", "net"]
      && labels.allSatisfy { label in
        !label.isEmpty && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      }
  }
  private static let productionHosts: Set<String> = ["registry.monero.one", "mirror.monero.one"]
  private static let stagingHosts: Set<String> = ["staging-registry.monero.one", "staging-mirror.monero.one"]
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

/// Makes the phone's DeviceCheck token. Tests stand in for the platform.
protocol UsernameDeviceTokens {
  var isSupported: Bool { get }
  func generateToken() async throws -> Data
}

struct AppleDeviceTokens: UsernameDeviceTokens {
  var isSupported: Bool { DCDevice.current.isSupported }
  func generateToken() async throws -> Data { try await DCDevice.current.generateToken() }
}

/// The `device` part of a claim (registry README, "Device gates").
enum UsernameDevice {
  /// Debug builds may send the dev proof when the phone cannot make a
  /// token (a simulator). A release build never sends it.
  #if DEBUG
    static let allowsDevProof = true
  #else
    static let allowsDevProof = false
  #endif

  /// Lowercase hex of HMAC-SHA256(key: the wallet's 32-byte private view
  /// key, message: "oah-registry/claim-key/v1"). The same wallet gives the
  /// same key on every retry. Made when needed; never stored or logged.
  static func claimKey(privateViewKey: Data) -> String? {
    guard privateViewKey.count == 32 else { return nil }
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("oah-registry/claim-key/v1".utf8), using: SymmetricKey(data: privateViewKey))
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  /// The 32 bytes of a 64-character hex key, or nil.
  static func keyBytes(hex: String) -> Data? {
    let digits = Array(hex.utf8)
    guard digits.count == 64 else { return nil }
    var bytes = Data(capacity: 32)
    for i in stride(from: 0, to: 64, by: 2) {
      guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else { return nil }
      bytes.append(high << 4 | low)
    }
    return bytes
  }
  private static func nibble(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
  }

  /// base64url without padding, as the registry decodes `device.proof`.
  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The `ios` proof: base64url of {"device_token", "claim_key"}, where the
  /// token is the standard base64 of the DeviceCheck token.
  static func iosProof(token: Data, claimKey: String) throws -> String {
    let json = try JSONSerialization.data(
      withJSONObject: ["device_token": token.base64EncodedString(), "claim_key": claimKey],
      options: [.sortedKeys, .withoutEscapingSlashes])
    return base64URL(json)
  }

  /// The dev proof that a local dev registry accepts. A release build has
  /// none, whatever the caller asks.
  private static func devProof(deviceID: String, allowed: Bool) -> [String: String]? {
    #if DEBUG
      return allowed ? ["platform": "dev", "proof": base64URL(Data(deviceID.utf8))] : nil
    #else
      return nil
    #endif
  }

  /// The proof for one claim attempt. `featureUnsupported` means this phone
  /// can never make a token; other platform errors can pass on a retry.
  @MainActor
  static func proof(
    claimKey: String, deviceID: String, tokens: UsernameDeviceTokens, allowDevProof: Bool
  ) async throws -> [String: String] {
    guard tokens.isSupported else {
      if let dev = devProof(deviceID: deviceID, allowed: allowDevProof) { return dev }
      throw UsernameFailure.deviceUnsupported
    }
    let token: Data
    do {
      token = try await tokens.generateToken()
    } catch let error as DCError where error.code == .featureUnsupported {
      if let dev = devProof(deviceID: deviceID, allowed: allowDevProof) { return dev }
      throw UsernameFailure.deviceUnsupported
    } catch {
      throw UsernameFailure.retry
    }
    guard !token.isEmpty else { throw UsernameFailure.retry }
    return ["platform": "ios", "proof": try iosProof(token: token, claimKey: claimKey)]
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
  private let deviceTokens: UsernameDeviceTokens
  private let allowDevProof: Bool
  init(
    configuration: UsernameConfiguration, session: URLSession? = nil,
    deviceTokens: UsernameDeviceTokens = AppleDeviceTokens(),
    allowDevProof: Bool = UsernameDevice.allowsDevProof
  ) {
    self.configuration = configuration
    self.deviceTokens = deviceTokens
    self.allowDevProof = allowDevProof
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
      if code == "geo.blocked" { throw UsernameFailure.regionBlocked }
      if code == "device.invalid" || code == "device.unsupported" { throw UsernameFailure.deviceUnsupported }
      if code == "device.unavailable" { throw UsernameFailure.retry }
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
  /// `ownsSubaddress` is true for a subaddress of the open wallet: a name
  /// that already points to one comes back with no new claim. It runs only
  /// for a record that passed every check, and may list a subaddress that
  /// the wallet does not list yet.
  func claim(
    displayHandle: String, walletKey: String, network: String, store: UsernameStore,
    makeSubaddress: () async throws -> String,
    sign: (String, String) throws -> String,
    claimKey: () throws -> String,
    ownsSubaddress: (String) async throws -> Bool,
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
    guard let rules = String(data: rulesData, encoding: .utf8) else { throw UsernameFailure.verification }
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
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
      // This wallet already holds the name: a new phone, a restored wallet
      // or cleared app data.
      if isCurrentWallet(),
        let binding = try await restore(
          existing, handle: handle, displayHandle: displayHandle, walletKey: walletKey,
          network: network, rules: rules, owns: ownsSubaddress, isCurrentWallet: isCurrentWallet,
          store: store)
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
    guard let nonce = nonceReply["nonce"] as? String else { throw UsernameFailure.verification }
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    let unsigned = try OAHCore.call([
      "op": "prepare_claim", "handle": handle, "subaddress": subaddress,
      "nonce": nonce, "network": network, "rules": rules, "rules_hash": configuration.rulesHash,
    ])
    guard let bytes = unsigned["record"] as? String, let hash = unsigned["record_hash"] as? String,
      let message = unsigned["signing_message"] as? String
    else { throw UsernameFailure.verification }
    let signature = try sign(message, subaddress)
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    // A new token for each attempt, made before the claim is saved: a phone
    // that cannot make one leaves no saved claim behind.
    let device = try await UsernameDevice.proof(
      claimKey: claimKey(), deviceID: store.state.deviceID, tokens: deviceTokens,
      allowDevProof: allowDevProof)
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    let pending = PendingUsernameClaim(
      walletKey: walletKey, network: network, handle: handle,
      displayHandle: displayHandle, subaddress: subaddress, nonce: nonce, unsignedRecord: bytes,
      recordHash: hash, ownerSignature: signature, registrarKey: configuration.registrarKey,
      rules: rules, rulesHash: configuration.rulesHash)
    // Persist before POST: if the reply is lost, check this exact signed
    // genesis on the next attempt instead of consuming another claim.
    try store.savePending(pending)
    return try await submit(pending, device: device, store: store)
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

  private func submit(
    _ pending: PendingUsernameClaim, device: [String: String], store: UsernameStore
  ) async throws -> UsernameBinding {
    guard pending.registrarKey == configuration.registrarKey,
      pending.rulesHash == configuration.rulesHash
    else {
      throw UsernameFailure.verification
    }
    do {
      let response = try object(
        await request(
          "claims",
          body: [
            "nonce": pending.nonce,
            "record": pending.unsignedRecord, "owner_signature": pending.ownerSignature,
            "device": device,
            "terms_version": configuration.termsVersion,
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
      // The registry refused before it wrote anything: the claim is gone.
      switch error {
      case .noFreeClaim, .unavailable, .regionBlocked, .deviceUnsupported: try store.savePending(nil)
      default: break
      }
      throw error
    }
  }

  /// The found name as this wallet's binding, or nil when a check fails.
  /// The chain must be one record that is the head, with no tombstone, and
  /// the claim checks (registrar and owner signatures, handle, network,
  /// rules) must pass for a subaddress of the open wallet. No nonce,
  /// signature or device token is made, and the phone's free claim stays.
  /// A chain with later records (a rotation, a subhandle) stays
  /// unavailable: the app makes none, and `verify_claim` checks a genesis
  /// head only.
  private func restore(
    _ found: [String: Any], handle: String, displayHandle: String, walletKey: String,
    network: String, rules: String, owns: (String) async throws -> Bool,
    isCurrentWallet: () -> Bool, store: UsernameStore
  ) async throws -> UsernameBinding? {
    guard found["handle"] as? String == handle, found["tombstoned"] as? Bool == false,
      let owner = found["owner"] as? String,
      let head = found["head"] as? [String: Any], head["seq"] as? Int == 0,
      let hash = head["record_hash"] as? String, found["genesis_hash"] as? String == hash,
      let rows = found["records"] as? [[String: Any]], rows.count == 1,
      rows[0]["record_hash"] as? String == hash, let record = rows[0]["record"] as? String
    else { return nil }
    // The checks of a claim's reply, with the found head and owner in place
    // of a saved claim. It is never saved and holds no request or signature.
    let held = PendingUsernameClaim(
      walletKey: walletKey, network: network, handle: handle, displayHandle: displayHandle,
      subaddress: owner, nonce: "", unsignedRecord: "", recordHash: hash, ownerSignature: "",
      registrarKey: configuration.registrarKey, rules: rules, rulesHash: configuration.rulesHash)
    // The record must verify before the wallet is asked: a record that
    // fails never makes the wallet list a subaddress.
    guard (try? OAHCore.call(Self.claimCheck(record, pending: held))) != nil else { return nil }
    guard try await owns(owner) else { return nil }
    guard isCurrentWallet() else { throw UsernameFailure.walletChanged }
    do {
      return try accept(record, pending: held, usesFreeClaim: false, store: store)
    } catch UsernameFailure.verification { return nil }
  }

  private func accept(
    _ record: String, pending: PendingUsernameClaim, usesFreeClaim: Bool = true,
    store: UsernameStore
  ) throws -> UsernameBinding {
    do {
      _ = try OAHCore.call(Self.claimCheck(record, pending: pending))
    } catch { throw UsernameFailure.verification }
    let binding = UsernameBinding(
      walletKey: pending.walletKey, network: pending.network,
      handle: pending.handle, displayHandle: pending.displayHandle, subaddress: pending.subaddress,
      genesisHash: pending.recordHash, record: record, claimedAt: Date())
    try store.accept(binding, usesFreeClaim: usesFreeClaim)
    return binding
  }
}
