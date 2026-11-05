import CryptoKit
import Foundation

/// Why the registry holds a name (registry README, "The valve").
enum UsernameHoldReason: String, Codable, CaseIterable {
  /// A court order or another binding legal demand.
  case order
  /// A notice that the registry received (a scam, an impersonation, a
  /// trademark misuse).
  case notice
  /// A sanctions match.
  case sanctions
  /// A breach of the Username Terms.
  case terms

  /// A `notice` or `terms` hold lets the holder retire the name. An `order`
  /// or `sanctions` hold refuses a retire with the same 451: the law can
  /// require the registry to keep those records.
  var allowsRetire: Bool { self == .notice || self == .terms }
}

/// The newest record of a name. A retire signs a tombstone at `seq + 1`
/// over `recordHash`.
struct UsernameHead: Equatable, Codable {
  let seq: UInt32
  /// Lowercase hex of the record hash.
  let recordHash: String

  /// `{"seq", "record_hash"}` as the registry sends it, or nil.
  init?(json: Any?) {
    guard let object = json as? [String: Any], let number = object["seq"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), let value = object["seq"] as? Int,
      let seq = UInt32(exactly: value),
      let hash = object["record_hash"] as? String, UsernameEnvironment.isHex64(hash)
    else { return nil }
    self.seq = seq
    recordHash = hash
  }
  init(seq: UInt32, recordHash: String) {
    self.seq = seq
    self.recordHash = recordHash
  }
}

/// A hold whose notice passed the signature check with the pinned registrar
/// key. The handle, the reason and the date come from the signed notice
/// only; `head` comes from the unsigned part of the answer.
struct UsernameHold: Equatable, Codable {
  let handle: String
  let reason: UsernameHoldReason
  let heldAt: Date
  /// Nil when the registry sent no head: then no retire can be signed.
  let head: UsernameHead?

  /// The holder may sign a retire: a `notice` or `terms` hold with a head.
  var allowsRetire: Bool { reason.allowsRetire && head != nil }

  /// The first line of a hold notice: its domain tag.
  static let noticeTag = "oah-registry/hold/v1"

  /// The hold in a `451 name.held` answer for `handle`. Nil when the answer
  /// is not one, or when its notice fails a check (the signature, the zone,
  /// the handle, the reason, the format). The caller then shows its generic
  /// error, with no reason.
  static func parse(
    _ body: [String: Any], handle: String, registrarKey: String, zone: String = "monero.one"
  ) -> UsernameHold? {
    guard (body["error"] as? [String: Any])?["code"] as? String == "name.held",
      let hold = body["hold"] as? [String: Any], let notice = hold["notice"] as? String,
      let signature = (hold["signature"] as? String).flatMap(UsernameDevice.base64URLDecode),
      UsernameRegistrar.isSigned(Data(notice.utf8), signature: signature, key: registrarKey)
    else { return nil }
    let lines = notice.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count == 6, lines[0] == noticeTag, lines[1] == "zone " + zone,
      lines[2] == "handle " + handle, lines[3].hasPrefix("reason "), lines[4].hasPrefix("held_at "),
      lines[5].isEmpty,
      let reason = UsernameHoldReason(rawValue: String(lines[3].dropFirst(7))),
      let seconds = Int64(lines[4].dropFirst(8)), String(seconds) == lines[4].dropFirst(8)
    else { return nil }
    // The head is optional: a hold without one shows its reason but offers
    // no retire.
    let head = hold["head"].flatMap { UsernameHead(json: $0) }
    return UsernameHold(
      handle: handle, reason: reason, heldAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
      head: head)
  }
}

extension UsernameDevice {
  /// Strict base64url without padding, as the registry encodes records and
  /// Ed25519 signatures: nil for padding, another alphabet or a
  /// non-canonical form.
  static func base64URLDecode(_ text: String) -> Data? {
    guard text.utf8.count % 4 != 1,
      text.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
      })
    else { return nil }
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
    guard let data = Data(base64Encoded: standard), base64URL(data) == text else { return nil }
    return data
  }
}

/// The registrar's Ed25519 signatures, checked with the pinned registrar key.
enum UsernameRegistrar {
  /// True when `signature` is the registrar's 64-byte Ed25519 signature of
  /// `message`, under the 64-hex-digit public `key`.
  static func isSigned(_ message: Data, signature: Data, key: String) -> Bool {
    guard signature.count == 64, UsernameEnvironment.isHex64(key),
      let raw = UsernameDevice.keyBytes(hex: key),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { return false }
    return publicKey.isValidSignature(Data(signature), for: message)
  }
}

/// The OAH1 tombstone (oah SPEC.md and oah-core `record.rs`):
///
///     header = "OAH1" type:u8 (4) handle_len:u8 handle seq:u32be prev:32
///     body   = (empty)
///     record_hash = SHA-256(header || body)
///     message     = "oah/tombstone/v1:" || lowercase hex(record_hash)
///
/// oah-mobile has no tombstone call, and this header is the whole record, so
/// the app builds it here. The tests check it against the oah vectors.
enum UsernameTombstone {
  /// The unsigned record, or nil when a value is not valid: a handle that is
  /// not a lowercase label, a `seq` of 0, or a `prev` that is not 64
  /// lowercase hex digits.
  static func unsigned(handle: String, seq: UInt32, prev: String) -> Data? {
    guard isLabel(handle), seq > 0, UsernameEnvironment.isHex64(prev),
      let prevBytes = UsernameDevice.keyBytes(hex: prev)
    else { return nil }
    var bytes = Data("OAH1".utf8)
    bytes.append(4)
    bytes.append(UInt8(handle.utf8.count))
    bytes.append(contentsOf: Array(handle.utf8))
    bytes.append(contentsOf: [UInt8(seq >> 24 & 0xff), UInt8(seq >> 16 & 0xff), UInt8(seq >> 8 & 0xff), UInt8(seq & 0xff)])
    bytes.append(prevBytes)
    return bytes
  }

  static func recordHash(_ unsigned: Data) -> String {
    SHA256.hash(data: unsigned).map { String(format: "%02x", $0) }.joined()
  }

  /// The ASCII text the owner signs, with the wallet's existing signer.
  static func signingMessage(_ unsigned: Data) -> String {
    "oah/tombstone/v1:" + recordHash(unsigned)
  }

  /// True when the registry's reply is this tombstone: the same unsigned
  /// bytes, one owner signature, and the registrar's countersignature of
  /// the signing message.
  static func isCountersigned(_ record: Data, unsigned: Data, registrarKey: String) -> Bool {
    let bytes = Data(record)
    guard bytes.count == unsigned.count + 128, Data(bytes.prefix(unsigned.count)) == unsigned else {
      return false
    }
    return UsernameRegistrar.isSigned(
      Data(signingMessage(unsigned).utf8), signature: Data(bytes.suffix(64)), key: registrarKey)
  }

  /// A record that the registry serves, read as a tombstone of `handle`:
  /// its unsigned bytes, `seq` and `prev`, when the record is that
  /// tombstone with one owner signature and the registrar's
  /// countersignature under `registrarKey`. Nil for any other record.
  static func countersigned(_ record: Data, handle: String, registrarKey: String)
    -> (unsigned: Data, seq: UInt32, prev: String)?
  {
    let bytes = [UInt8](record)
    let length = 4 + 1 + 1 + handle.utf8.count + 4 + 32
    guard bytes.count == length + 128 else { return nil }
    let at = 6 + handle.utf8.count
    let seq = bytes[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let prev = bytes[(at + 4)..<length].map { String(format: "%02x", $0) }.joined()
    // The rebuilt header must be the record's own: "OAH1", type 4, this handle.
    guard let unsigned = unsigned(handle: handle, seq: seq, prev: prev),
      unsigned == Data(bytes[0..<length]),
      isCountersigned(record, unsigned: unsigned, registrarKey: registrarKey)
    else { return nil }
    return (unsigned, seq, prev)
  }

  /// oah-core `validate_label`: 3 to 15 of a-z, 0-9 and _, a letter first,
  /// no `__`. The blocked-name list is not checked: a name that the list
  /// blocks later can still retire.
  static func isLabel(_ handle: String) -> Bool {
    let bytes = Array(handle.utf8)
    guard (3...15).contains(bytes.count), (97...122).contains(bytes[0]) else { return false }
    return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
      && !handle.contains("__")
  }
}

/// The registrar's signed statement that a name, with its genesis, was
/// retired and erased (registry README, "Retired statement", audit F12b).
/// After the erasure a plain lookup answers the `404 handle.not_found` of a
/// name that never existed. A lookup with `?genesis=<64 lowercase hex>`
/// gets the same 404 with a top-level `retired` object
/// `{"handle", "genesis_hash", "statement", "signature"}` when the
/// registry retired that name with that genesis. The app never trusts the
/// server's text: it builds the statement itself and checks the signature.
enum UsernameRetiredStatement {
  /// The first line of a retired statement: its domain tag.
  static let tag = "oah-registry/retired/v1"

  /// The signed bytes, as the registry's `retired_text` builds them.
  static func text(zone: String, handle: String, genesisHash: String) -> String {
    "\(tag)\nzone \(zone)\nhandle \(handle)\ngenesis_hash \(genesisHash)\n"
  }

  /// True when `body`, the JSON of a lookup's 404, proves that `handle`
  /// with `genesisHash` was retired and erased. Each check must pass:
  /// - `error.code` is `handle.not_found`;
  /// - `handle` is a lowercase label and `genesisHash` is 64 lowercase hex;
  /// - `retired.handle` is `handle` and `retired.genesis_hash` is
  ///   `genesisHash`;
  /// - `retired.statement` is the app's own `text(zone:handle:genesisHash:)`,
  ///   byte for byte;
  /// - `retired.signature` is strict base64url of 64 bytes, and a valid
  ///   Ed25519 signature of the app's own text under the pinned
  ///   `registrarKey`.
  /// Anything else is false: the name stays.
  static func proves(
    _ body: [String: Any], handle: String, genesisHash: String, registrarKey: String, zone: String
  ) -> Bool {
    guard (body["error"] as? [String: Any])?["code"] as? String == "handle.not_found",
      UsernameTombstone.isLabel(handle), UsernameEnvironment.isHex64(genesisHash),
      let retired = body["retired"] as? [String: Any],
      retired["handle"] as? String == handle, retired["genesis_hash"] as? String == genesisHash,
      let signature = (retired["signature"] as? String).flatMap(UsernameDevice.base64URLDecode)
    else { return false }
    let own = text(zone: zone, handle: handle, genesisHash: genesisHash)
    guard retired["statement"] as? String == own else { return false }
    return UsernameRegistrar.isSigned(Data(own.utf8), signature: signature, key: registrarKey)
  }
}

/// One free name per phone per 12 months (registry README, "Claim-slot
/// safety"). The platforms date a phone mark by its UTC month only, and the
/// registry keeps the mark in force while `month(now) <= month(mark) + 12`
/// (`mark_in_force`). So the phone is free again at the first instant of
/// the 13th month after the month of the claim.
enum UsernameClaimSlot {
  /// `claims.period_months` of the pinned rules (`rulesHash`).
  static let periodMonths = 12
  /// The mark is written before the reply, and a phone clock can be a
  /// little off. A claim in the last day of a month may be dated in the
  /// next month, so the month is read one day later: the date may be late,
  /// never early.
  static let margin: TimeInterval = 86_400

  /// The first instant this phone can claim again after a claim at
  /// `claimedAt`.
  static func nextFreeClaim(after claimedAt: Date) -> Date {
    startOfMonth(monthIndex(claimedAt.addingTimeInterval(margin)) + periodMonths + 1)
  }

  /// A UTC month as `year * 12 + (month - 1)`, as the registry counts it.
  static func monthIndex(_ date: Date) -> Int {
    let parts = utc.dateComponents([.year, .month], from: date)
    return (parts.year ?? 1970) * 12 + (parts.month ?? 1) - 1
  }

  /// The first instant of a UTC month index.
  static func startOfMonth(_ index: Int) -> Date {
    let parts = DateComponents(year: index / 12, month: index % 12 + 1, day: 1)
    return utc.date(from: parts) ?? .distantFuture
  }

  private static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
}

/// The registry's answer for the wallet's own name.
enum UsernameNameStatus: Equatable {
  /// The name is live, at this head.
  case live(UsernameHead)
  /// The registry holds the name, and the notice passed its check.
  case held(UsernameHold)
  /// The chain ends in this name's tombstone, countersigned by the
  /// registrar (the erasure runs at the next epoch), or the epoch erased
  /// the name and the registrar signed its retired statement for this
  /// genesis (`UsernameRetiredStatement`).
  case retired
  /// The registry has no such name (erased, or never registered there),
  /// and no signed retired statement came with the 404: alone it proves
  /// no retire.
  case notFound
}

/// What the @name screen shows for the wallet's own name. Read it with
/// `UsernameStore.nameState(for:)`; it changes when the store publishes.
struct UsernameNameState: Equatable {
  /// The checked hold, or nil while the name is live or its state is not
  /// known. A hold whose notice fails its check is never set.
  var hold: UsernameHold?
  /// The reason for the gray On hold row.
  var heldReason: UsernameHoldReason? { hold?.reason }
  var heldAt: Date? { hold?.heldAt }
  /// The red Retire Name row shows: a live name, or a `notice` or `terms`
  /// hold. An `order` or `sanctions` hold offers no action.
  var retireAllowed: Bool { hold.map(\.allowsRetire) ?? true }
  /// The date for the retire confirmation ("You can claim a new name after
  /// ..."): this phone's next free claim, from the claim that used it. Nil
  /// when the app knows of no claim that blocks this phone now (a name that
  /// came back on a new phone, or a fresh install). Show it as "after" the
  /// local day of this instant: that day ends after the instant in every
  /// time zone, so the text never names a date too early.
  var nextFreeClaim: Date?
}
