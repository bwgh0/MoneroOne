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

/// A retire this phone signed, saved before its POST. A later lookup can
/// match the registrar's countersigned copy of `record`. While it is saved,
/// an unsigned "gone" answer (a 404, `chain.record_after_tombstone`) can
/// end the retire; with none saved, those answers keep the name.
struct UsernameRetireAttempt: Codable, Equatable {
  let walletKey: String
  let network: String
  let handle: String
  let genesisHash: String
  /// base64url of the unsigned tombstone.
  let record: String

  init(binding: UsernameBinding, unsigned: Data) {
    walletKey = binding.walletKey
    network = binding.network
    handle = binding.handle
    genesisHash = binding.genesisHash
    record = UsernameDevice.base64URL(unsigned)
  }
  func matches(_ binding: UsernameBinding) -> Bool {
    walletKey == binding.walletKey && network == binding.network && handle == binding.handle
      && genesisHash == binding.genesisHash
  }
}

struct UsernameLocalState: Codable {
  var bindings: [UsernameBinding] = []
  var pending: PendingUsernameClaim?
  var nextFreeClaim: Date?
  var deviceID = UUID().uuidString
  /// Optional, so a state saved before retires decodes.
  var retires: [UsernameRetireAttempt]?
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
  /// Each change is saved first and is in memory at once. While the flow
  /// holds updates, its publish waits, so Home does not redraw under the
  /// claim's motion.
  private(set) var state = UsernameLocalState() {
    willSet {
      if holdsUpdates { heldUpdate = true } else { objectWillChange.send() }
    }
  }
  @Published private(set) var storageError = false
  private let persistence: UsernamePersistence
  private var claiming = false
  private var holdsUpdates = false
  private var heldUpdate = false

  func beginClaim() throws {
    guard !claiming else { throw UsernameFailure.pendingClaim }
    claiming = true
  }
  func endClaim() { claiming = false }
  /// The claim flow holds the publish of `state` from the claim's start
  /// until its result has animated in. Saves are not held.
  func holdUpdates() { holdsUpdates = true }
  /// Sends the held change, if any, once.
  func releaseUpdates() {
    holdsUpdates = false
    guard heldUpdate else { return }
    heldUpdate = false
    objectWillChange.send()
  }

  init(persistence: UsernamePersistence = UsernameKeychain()) {
    self.persistence = persistence
    #if DEBUG
      Self.applyTestReset(ProcessInfo.processInfo.environment["USERNAME_TEST_RESET"], to: persistence)
    #endif
    reload()
  }
  #if DEBUG
    /// Test hook, debug builds only (release builds compile it out). The
    /// launch environment variable `USERNAME_TEST_RESET` starts the app with
    /// no saved usernames, so one test phone can claim again:
    /// - `1` clears the claims, the pending claim, the free-claim date, the
    ///   device ID and the staging test device ID (the registry sees a new
    ///   phone).
    /// - `keep-device` clears the same but keeps both device IDs (the
    ///   registry sees the same phone, to test `noFreeClaim`).
    /// Any other value changes nothing.
    static func applyTestReset(
      _ mode: String?, to persistence: UsernamePersistence, defaults: UserDefaults = .standard
    ) {
      guard mode == "1" || mode == "keep-device" else { return }
      var cleared = UsernameLocalState()
      if mode == "keep-device", let deviceID = (try? persistence.read())?.deviceID {
        cleared.deviceID = deviceID
      }
      try? persistence.write(cleared)
      if mode == "1" { defaults.removeObject(forKey: UsernameDevice.testDeviceIDKey) }
    }
  #endif
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
  /// `usesFreeClaim` is false for a name the wallet already held: no claim
  /// ran on this phone, so its free claim date stays.
  func accept(_ binding: UsernameBinding, usesFreeClaim: Bool = true) throws {
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
    if usesFreeClaim {
      // The registry's rule, rounded up. A later saved date stays.
      let free = UsernameClaimSlot.nextFreeClaim(after: binding.claimedAt)
      next.nextFreeClaim = max(free, next.nextFreeClaim ?? free)
    }
    try persistence.write(next)
    state = next
  }
  /// After a retire: the name, its saved claim, its saved retire and its
  /// hold go. The free claim date stays, so Home hides the invite until the
  /// phone can claim again. Call it only after an answer that proves the
  /// retire (see `UsernameRegistry.retire`).
  func forget(_ binding: UsernameBinding) throws {
    guard !storageError else { throw UsernameFailure.storage }
    var next = state
    next.bindings.removeAll { $0.id == binding.id && $0.genesisHash == binding.genesisHash }
    if let pending = next.pending, pending.walletKey == binding.walletKey,
      pending.network == binding.network, pending.handle == binding.handle
    {
      next.pending = nil
    }
    next.retires?.removeAll { $0.matches(binding) }
    try persistence.write(next)
    holds[Self.holdKey(binding.handle, binding.network)] = nil
    state = next
  }
  /// Saves a signed retire before its POST, in place of the wallet's
  /// earlier one on this network.
  func saveRetire(_ attempt: UsernameRetireAttempt) throws {
    guard !storageError else { throw UsernameFailure.storage }
    var next = state
    var retires = next.retires ?? []
    retires.removeAll { $0.walletKey == attempt.walletKey && $0.network == attempt.network }
    retires.append(attempt)
    next.retires = retires
    try persistence.write(next)
    state = next
  }
  /// The retire this phone signed and saved for this name, if any.
  func retireAttempt(for binding: UsernameBinding) -> UsernameRetireAttempt? {
    guard !storageError else { return nil }
    return state.retires?.first { $0.matches(binding) }
  }
  /// The checked hold of each name the registry holds, by network and
  /// handle. Kept in memory: the @name screen checks again when it opens.
  @Published private(set) var holds: [String: UsernameHold] = [:]
  /// Saves the hold of a name, or clears it (nil) when the registry shows
  /// the name live again.
  func noteHold(_ hold: UsernameHold?, handle: String, network: String) {
    let key = Self.holdKey(handle, network)
    guard holds[key] != hold else { return }
    holds[key] = hold
  }
  func hold(for binding: UsernameBinding) -> UsernameHold? {
    holds[Self.holdKey(binding.handle, binding.network)]
  }
  private static func holdKey(_ handle: String, _ network: String) -> String { network + ":" + handle }
  /// This phone's next free claim while it is still ahead, else nil. Home
  /// hides the invite until then (`hasLocalClaimSlot`).
  var inviteHiddenUntil: Date? {
    guard let date = state.nextFreeClaim, date > Date() else { return nil }
    return date
  }
  /// What the @name screen shows for this wallet's name.
  func nameState(for binding: UsernameBinding) -> UsernameNameState {
    UsernameNameState(hold: hold(for: binding), nextFreeClaim: inviteHiddenUntil)
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
