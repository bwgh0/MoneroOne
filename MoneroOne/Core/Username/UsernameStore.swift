import Foundation
import Security

struct UsernameBinding: Codable, Equatable, Identifiable {
  let walletKey: String
  let network: String
  let handle: String
  let displayHandle: String
  let subaddress: String
  let genesisHash: String
  let record: String
  let claimedAt: Date
  var id: String { network + ":" + walletKey }
  var shortName: String { "@" + displayHandle }
  var externalAddress: String { handle + "@monero.one" }
  var shareURL: URL { URL(string: "https://monero.one/u/" + handle)! }
}

struct PendingUsernameClaim: Codable {
  let walletKey: String
  let network: String
  let handle: String
  let displayHandle: String
  let subaddress: String
  let nonce: String
  let unsignedRecord: String
  let recordHash: String
  let ownerSignature: String
  let registrarKey: String
  let rules: String
  let rulesHash: String
}

struct UsernameLocalState: Codable {
  var bindings: [UsernameBinding] = []
  var pending: PendingUsernameClaim?
  var nextFreeClaim: Date?
  var deviceID = UUID().uuidString
}

protocol UsernamePersistence {
  func read() throws -> UsernameLocalState
  func write(_ state: UsernameLocalState) throws
}

/// Public usernames still identify a wallet. Keep the mapping in the
/// device-only Keychain, rather than plain preferences or diagnostic logs.
struct UsernameKeychain: UsernamePersistence {
  let service: String
  init(service: String? = nil) {
    #if DEBUG
      self.service = service ?? "one.monero.MoneroOne.usernames.development.v1"
    #else
      self.service = service ?? "one.monero.MoneroOne.usernames.production.v1"
    #endif
  }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: "state",
    ]
  }
  func read() throws -> UsernameLocalState {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return UsernameLocalState() }
    guard status == errSecSuccess, let data = result as? Data else { throw UsernameFailure.storage }
    return try JSONDecoder().decode(UsernameLocalState.self, from: data)
  }
  func write(_ state: UsernameLocalState) throws {
    let data = try JSONEncoder().encode(state)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw UsernameFailure.storage }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw UsernameFailure.storage
    }
  }
}

@MainActor
final class UsernameStore: ObservableObject {
  static let shared: UsernameStore = {
    #if DEBUG && targetEnvironment(simulator)
      if CommandLine.arguments.contains("--uitesting")
        && CommandLine.arguments.contains("--balance-history-fixture")
        && CommandLine.arguments.contains("--username-preview")
      {
        return UsernameStore(persistence: UsernamePreviewPersistence())
      }
    #endif
    return UsernameStore()
  }()
  @Published private(set) var state = UsernameLocalState()
  @Published private(set) var storageError = false
  private let persistence: UsernamePersistence
  private var claiming = false

  func beginClaim() throws {
    guard !claiming else { throw UsernameFailure.pendingClaim }
    claiming = true
  }
  func endClaim() { claiming = false }

  init(persistence: UsernamePersistence = UsernameKeychain()) {
    self.persistence = persistence
    reload()
  }
  func reload() {
    do {
      state = try persistence.read()
      storageError = false
    } catch { storageError = true }
  }
  func binding(walletKey: String, network: String) -> UsernameBinding? {
    guard !walletKey.isEmpty, !storageError else { return nil }
    return state.bindings.first { $0.walletKey == walletKey && $0.network == network }
  }
  func savePending(_ pending: PendingUsernameClaim?) throws {
    guard !storageError else { throw UsernameFailure.storage }
    var next = state
    next.pending = pending
    try persistence.write(next)
    state = next
  }
  /// A deleted wallet can never finish its saved claim. Clearing it frees
  /// the claim for the other wallets on this phone.
  func clearPending(walletKey: String) throws {
    guard !walletKey.isEmpty, state.pending?.walletKey == walletKey else { return }
    try savePending(nil)
  }
  func accept(_ binding: UsernameBinding) throws {
    guard !storageError else { throw UsernameFailure.storage }
    var next = state
    if let old = next.bindings.first(where: { $0.id == binding.id }),
      old.genesisHash != binding.genesisHash
    {
      throw UsernameFailure.verification
    }
    next.bindings.removeAll { $0.id == binding.id }
    next.bindings.append(binding)
    next.pending = nil
    next.nextFreeClaim = Calendar(identifier: .gregorian).date(
      byAdding: .month, value: 12, to: binding.claimedAt)
    try persistence.write(next)
    state = next
  }
  /// While a saved claim may hold a name, only its own wallet offers a
  /// claim. Other wallets show nothing until a check settles it.
  func offersClaim(walletKey: String, network: String) -> Bool {
    guard let pending = state.pending else { return true }
    return pending.walletKey == walletKey && pending.network == network
  }
  var hasLocalClaimSlot: Bool {
    !storageError && (state.nextFreeClaim.map { $0 <= Date() } ?? true)
  }
}

#if DEBUG && targetEnvironment(simulator)
  /// Opt-in visual fixture: no Keychain writes, signing, or registry calls.
  private struct UsernamePreviewPersistence: UsernamePersistence {
    func read() throws -> UsernameLocalState {
      let handle = ProcessInfo.processInfo.environment["USERNAME_PREVIEW_HANDLE"] ?? "Joe"
      return UsernameLocalState(
        bindings: [
          UsernameBinding(
            walletKey: "4" + String(repeating: "A", count: 94), network: "mainnet",
            handle: handle.lowercased(), displayHandle: handle, subaddress: "",
            genesisHash: "preview", record: "", claimedAt: Date())
        ], nextFreeClaim: .distantFuture)
    }
    func write(_ state: UsernameLocalState) throws { throw UsernameFailure.notConfigured }
  }
#endif
