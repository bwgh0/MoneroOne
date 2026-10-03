import Foundation
import Security

/// One payment link this device sent or received. The words are a bearer
/// secret: the record lives only in the Keychain (this device only), never
/// in UserDefaults, logs or backups.
struct EnvelopeRecord: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case sent
        case received
    }

    /// The envelope id `n`.
    let id: String
    let role: Role
    /// The 25 words. Nil once a received link is claimed here.
    var words: [String]?
    /// The envelope's primary address.
    var address: String
    var restoreHeight: UInt64
    /// `a`, piconero.
    var amount: UInt64
    var expiry: Int64
    var createdAt: Date
    var status: EnvelopeStatus
    /// Sent: the funding transaction.
    var fundingTxid: String?
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
    /// Last envelope sync.
    var lastBalance: UInt64?
    var confirmations: Int?
    var lastCheckedAt: Date?

    var link: EnvelopeLink? {
        guard let words else { return nil }
        return EnvelopeLink(words: words, restoreHeight: restoreHeight, amount: amount, expiry: expiry, id: id)
    }

    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiry)) }

    /// Status for display: Expired over pending and ready.
    func isExpired(now: Date = Date()) -> Bool {
        EnvelopeStatusRules.isExpired(status, expiry: expiry, now: now)
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
    }

    /// Saves or replaces a record. Throws when the Keychain refuses it: the
    /// sender must not fund an envelope whose words are not saved.
    func save(_ record: EnvelopeRecord) throws {
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
        if let index = records.firstIndex(where: { $0.id == record.id && $0.role == record.role }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

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
    }

    func remove(_ record: EnvelopeRecord) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: record),
        ]
        SecItemDelete(query as CFDictionary)
        records.removeAll { $0.id == record.id && $0.role == record.role }
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

enum EnvelopeStoreError: LocalizedError {
    case keychain(OSStatus)
    case verifyFailed

    var errorDescription: String? {
        String(localized: "Could not save the payment link on this iPhone. Nothing was sent.")
    }
}
