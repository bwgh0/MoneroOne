import Foundation
import Security

/// One payment link this device sent or received. The secret (v2) or the
/// words (v1) are a bearer secret: the record lives only in the Keychain
/// (this device only), never in UserDefaults, logs or backups.
struct EnvelopeRecord: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case sent
        case received
    }

    /// The envelope id (v1 `n`, v2 derived from the secret).
    let id: String
    let role: Role
    /// v1 links: the 25 words. Nil for v2 links, and in older records that already discarded their secret.
    var words: [String]?
    /// v2 links: the 16-byte link secret, lowercase hex. Nil for v1 links,
    /// and in older records that discarded their secret.
    var secret: String?
    /// The envelope's primary address.
    var address: String
    var restoreHeight: UInt64
    /// Piconero. Sent: the amount the sender meant. Received: `a` of a v1
    /// link; 0 for a v2 link until a check sees the envelope's balance.
    var amount: UInt64
    /// Unix seconds. Sent: creation + 30 days. Received: `e` of a v1 link;
    /// 0 (none) for a v2 link, which carries no expiry.
    var expiry: Int64
    var createdAt: Date
    var status: EnvelopeStatus
    /// Sent: the funding transaction.
    var fundingTxid: String?
    /// Persisted before signing/broadcast. An uncertain send is never funded again.
    var fundingStartedAt: Date?
    /// The funding attempt failed before anything reached the network (the
    /// transaction was never built, or a guard stopped it): no scan looks
    /// for its funding. Nil when the attempt may have gone out.
    var fundingNotSent: Bool?
    /// Sent: the claim fee reserve added to the funding amount, piconero.
    var feeReserve: UInt64?
    /// Sent: our reclaim sweep. Received: our claim sweep.
    var settleTxid: String?
    /// Piconero that the settle sweep moved.
    var settledAmount: UInt64?
    /// Name of the wallet that funded (sent) or received (claimed) it.
    var walletName: String?
    /// Id of the wallet that funded a sent link. Retry and the funding
    /// lookup run only in that wallet, so a link is never funded twice.
    var walletId: String?
    /// When our settle sweep went out.
    var settledAt: Date?
    /// A scan saw our settle sweep in a block. Until then a background look
    /// tells a sweep that waits from one that dropped.
    var settleSeenMined: Bool?
    /// The block height the last envelope scan reached.
    var lastScannedHeight: UInt64?
    /// The envelope's spends from before our current claim or reclaim: our
    /// earlier sweeps, kept when the link opened again, and the spends a
    /// scan saw while it was open. None of them is a claim that beat ours.
    /// Nil in records from before this field: none known.
    var spendsBeforeSettle: [String]?
    /// Last envelope sync.
    var lastBalance: UInt64?
    var confirmations: Int?
    /// Block height of the funding the last check saw mined. With the active
    /// wallet's daemon height it gives a live confirmation count without
    /// opening the envelope again.
    var fundingHeight: UInt64?
    var lastCheckedAt: Date?
    /// A received link: what a claim delivers, piconero. The last balance
    /// less wallet2's fee estimate for the claim sweep. Nil until a check
    /// (or the active wallet's estimate, for a record checked before this
    /// field) saw the link funded.
    var netAmount: UInt64?
    /// This iPhone's number for the link ("Link 7"), from one counter that
    /// sent and received links share. The store assigns it on the first
    /// save; nil only in a record that was never saved.
    var number: Int?
    /// The name the user gave the link. Local only: it never goes into the
    /// link, its URL, the share text or a transaction memo. Empty or nil
    /// means "use the number".
    var note: String?

    /// The longest note, in characters.
    static let noteLimit = 40

    /// The name the app shows: the note, else "Link 7".
    var displayName: String {
        Self.displayName(note: note, number: number)
    }

    static func displayName(note: String?, number: Int?) -> String {
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        if let number { return linkName(number) }
        return String(localized: "Payment link")
    }

    /// "Link 7": the default name for link number 7.
    static func linkName(_ number: Int) -> String {
        String(localized: "Link \(number)")
    }

    var link: EnvelopeLink? {
        if let secret, let bytes = [UInt8](hex: secret) {
            return EnvelopeLink(secret: bytes, restoreHeight: restoreHeight)
        }
        guard let words else { return nil }
        return EnvelopeLink(words: words, restoreHeight: restoreHeight, amount: amount, expiry: expiry, id: id)
    }

    /// Stores the secret of `link`: the v2 secret, or the v1 words.
    mutating func setSecret(from link: EnvelopeLink) {
        if let bytes = link.secret {
            secret = bytes.hexString
            words = nil
        } else {
            words = link.words
            secret = nil
        }
    }

    /// A settled link is open again: our claim or reclaim dropped, or money
    /// arrived after it. The old sweep no longer describes the link; its
    /// txid stays in `spendsBeforeSettle`, so a later scan that shows it
    /// reads it as ours.
    mutating func reopen() {
        if let settleTxid, !settleTxid.isEmpty { noteSpendsBeforeSettle([settleTxid]) }
        settleTxid = nil
        settledAmount = nil
        settledAt = nil
        settleSeenMined = nil
        if role == .received { walletName = nil }
    }

    /// Adds `txids` to `spendsBeforeSettle`, once each.
    mutating func noteSpendsBeforeSettle(_ txids: [String]) {
        var spends = spendsBeforeSettle ?? []
        for txid in txids where !txid.isEmpty && !spends.contains(txid) { spends.append(txid) }
        if !spends.isEmpty { spendsBeforeSettle = spends }
    }

    /// Legacy helper. Automatic claim cleanup must never call this.
    mutating func forgetSecret() {
        words = nil
        secret = nil
    }

    /// Nil when the link has no expiry (a received v2 link).
    var expiryDate: Date? { expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : nil }

    /// What the link holds as far as this device knows, piconero: the
    /// amount meant, else the balance the last check saw. Nil when unknown.
    var knownAmount: UInt64? {
        if amount > 0 { return amount }
        if let lastBalance, lastBalance > 0 { return lastBalance }
        return nil
    }

    /// A received link before its claim: what the claim delivers, piconero.
    /// The net amount when known, else the v1 link's amount (the sender
    /// put the claim fee on top), else the last balance. Nil when unknown.
    var claimAmount: UInt64? {
        if let netAmount, netAmount > 0 { return netAmount }
        return knownAmount
    }

    /// The balance less the claim sweep's fee; nil when the fee takes it all.
    static func net(balance: UInt64, fee: UInt64) -> UInt64? {
        balance > fee ? balance - fee : nil
    }

    /// Notes the balance a check saw. A received link also gets its net
    /// amount from `sweepFee`; with no fee estimate it keeps the old net
    /// amount only while the balance holds.
    mutating func noteBalance(_ balance: UInt64, sweepFee: UInt64?) {
        if role == .received {
            if let sweepFee {
                netAmount = Self.net(balance: balance, fee: sweepFee)
            } else if balance != lastBalance {
                netAmount = nil
            }
        }
        lastBalance = balance
    }

    /// A received link checked before the net amount existed: the active
    /// wallet's fee estimate stands in for the envelope's.
    var needsNetAmount: Bool {
        role == .received && !status.isSettled && link != nil && netAmount == nil
            && amount == 0 && (lastBalance ?? 0) > 0
    }

    /// Status for display: Expired over pending and ready.
    func isExpired(now: Date = Date()) -> Bool {
        EnvelopeStatusRules.isExpired(status, expiry: expiry, now: now)
    }

    /// A received link that never got money in its days to claim (see
    /// `EnvelopeStatusRules.isReceivedExpired`); `createdAt` is when this
    /// device got it.
    func isReceivedExpired(now: Date = Date()) -> Bool {
        EnvelopeStatusRules.isReceivedExpired(status, role: role, expiry: expiry, receivedAt: createdAt, now: now)
    }

    /// A received record we finished (claimed here) or that turned out empty.
    var isDone: Bool { status.isSettled }
}

/// Keychain-backed list of envelope records, one generic-password item per
/// record (service `one.monero.MoneroOne.paymentlinks`, account
/// `<role>.<id>`), readable after first unlock, this device only.
@MainActor
final class EnvelopeStore: ObservableObject {
    static let shared = EnvelopeStore()

    nonisolated static let service = "one.monero.MoneroOne.paymentlinks"

    @Published private(set) var records: [EnvelopeRecord] = []

    private let service: String

    init(service: String = EnvelopeStore.service) {
        self.service = service
        reload()
    }

    var sent: [EnvelopeRecord] {
        records.filter { $0.role == .sent }.sorted { $0.createdAt > $1.createdAt }
    }

    var received: [EnvelopeRecord] {
        records.filter { $0.role == .received }.sorted { $0.createdAt > $1.createdAt }
    }

    func record(id: String, role: EnvelopeRecord.Role) -> EnvelopeRecord? {
        records.first { $0.id == id && $0.role == role }
    }

    func reload() {
        records = loadAll()
        numberUnnumberedRecords()
        reconcileFundedRecords()
    }

    /// A sent link with a funding transaction is never Not funded: a check
    /// that missed its funding (its scan started above the funding block)
    /// wrote that. It waits for its funding again, and the next check scans
    /// the envelope from the funding block.
    private func reconcileFundedRecords() {
        for var record in records where record.role == .sent {
            let status = EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid)
            guard status != record.status else { continue }
            record.status = status
            if (try? write(record)) == nil, let index = index(of: record) {
                // The Keychain refused it: the status holds for this run.
                records[index] = record
            }
        }
    }

    /// The number the next new link gets ("Link 9"). One counter for sent
    /// and received links; it never goes back, so a removed link's number
    /// is not used again.
    var nextNumber: Int {
        max(lastNumber, records.compactMap(\.number).max() ?? 0) + 1
    }

    /// Saves or replaces a record. Throws when the Keychain refuses it: the
    /// sender must not fund an envelope whose words are not saved.
    ///
    /// The number and the note belong to the store: a saved record keeps its
    /// own, whatever the caller's copy holds, so a copy taken before a rename
    /// cannot undo it. A new record gets the next number; its note is kept.
    /// Use `setNote` to rename.
    func save(_ record: EnvelopeRecord) throws {
        var record = record
        if let stored = self.record(id: record.id, role: record.role) {
            record.number = stored.number ?? record.number
            record.note = stored.note
            record.fundingStartedAt = stored.fundingStartedAt ?? record.fundingStartedAt
            record.fundingTxid = stored.fundingTxid ?? record.fundingTxid
        }
        if record.number == nil {
            record.number = nextNumber
        }
        try write(record)
        if let number = record.number, number > lastNumber {
            lastNumber = number
        }
    }

    /// Renames a link. An empty note goes back to "Link 7".
    func setNote(_ note: String, id: String, role: EnvelopeRecord.Role) throws {
        guard var record = record(id: id, role: role) else { return }
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EnvelopeRecord.noteLimit))
        record.note = trimmed.isEmpty ? nil : trimmed
        try write(record)
    }

    /// Gives every record saved before link numbers its number, oldest first.
    private func numberUnnumberedRecords() {
        let unnumbered = records
            .filter { $0.number == nil }
            .sorted { ($0.createdAt, $0.role.rawValue, $0.id) < ($1.createdAt, $1.role.rawValue, $1.id) }
        for var record in unnumbered {
            let number = nextNumber
            record.number = number
            lastNumber = number
            if (try? write(record)) == nil, let index = index(of: record) {
                // The Keychain refused it: the number holds for this run.
                records[index] = record
            }
        }
    }

    private func write(_ record: EnvelopeRecord) throws {
        let data = try JSONEncoder().encode(record)
        let account = Self.account(for: record)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EnvelopeStoreError.keychain(status) }
        // Read back: the funding path relies on the words being there.
        guard loadOne(account: account) == record else { throw EnvelopeStoreError.verifyFailed }
        if let index = index(of: record) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    private func index(of record: EnvelopeRecord) -> Int? {
        records.firstIndex { $0.id == record.id && $0.role == record.role }
    }

    /// The highest number given out, kept apart from the records so that a
    /// removed link's number is not used again.
    private var lastNumber: Int {
        get { UserDefaults.standard.integer(forKey: lastNumberKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastNumberKey) }
    }

    private var lastNumberKey: String { "\(service).lastNumber" }

    /// A sent link that may still hold money.
    var hasUnsettledSentLinks: Bool {
        records.contains { $0.role == .sent && !$0.status.isSettled }
    }

    /// Remove All: every record and its secret leave the Keychain.
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        records = []
        UserDefaults.standard.removeObject(forKey: lastNumberKey)
    }

    // MARK: - Private

    nonisolated static func account(for record: EnvelopeRecord) -> String {
        "\(record.role.rawValue).\(record.id)"
    }

    private func loadOne(account: String) -> EnvelopeRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(EnvelopeRecord.self, from: data)
    }

    private func loadAll() -> [EnvelopeRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return loadOne(account: account)
        }
    }
}

extension Array where Element == UInt8 {
    /// Bytes from lowercase or uppercase hex; nil for an odd length or a
    /// non-hex character.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

enum EnvelopeStoreError: LocalizedError {
    case keychain(OSStatus)
    case verifyFailed

    var errorDescription: String? {
        String(localized: "Could not save the payment link on this iPhone. Nothing was sent.")
    }
}
