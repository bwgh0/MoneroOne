import Foundation
import Security

/// A person you send to: a name and one destination. App-wide, on this
/// iPhone only: no sync and no Contacts permission. A username becomes a
/// third kind later, with no migration.
struct Contact: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case address
        case openAlias
    }

    let id: UUID
    var name: String
    /// The address, or the OpenAlias name as it was typed.
    var destination: String
    var kind: Kind
    let createdAt: Date

    init(id: UUID = UUID(), name: String, destination: String, kind: Kind? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.destination = destination
        self.kind = kind ?? Self.kind(of: destination)
        self.createdAt = createdAt
    }

    /// An OpenAlias name is a name; anything else is an address.
    static func kind(of destination: String) -> Kind {
        if case .name = OpenAlias.classify(destination) { return .openAlias }
        return .address
    }

    /// The OpenAlias name of an OpenAlias contact.
    var openAliasName: OpenAliasName? {
        guard kind == .openAlias, case .name(let name) = OpenAlias.classify(destination) else { return nil }
        return name
    }

    /// The second line of a row: the OpenAlias name, or the 8…8 address.
    var shortDestination: String {
        kind == .openAlias ? destination : ReceiveAddressLogic.shortAddress(destination)
    }

    /// The monogram: the first letters of the name, else the person glyph.
    var initials: String? {
        OpenAlias.initials(recipientName: name, display: kind == .openAlias ? destination : "")
    }

    /// VoiceOver: the name first, then the short address or the OpenAlias name.
    var spokenLabel: String {
        "\(name), \(shortDestination)"
    }
}

/// Where the contact list is kept, encrypted.
protocol ContactVault {
    func read() -> Data?
    func write(_ data: Data?)
}

/// One Keychain item, readable after the first unlock and never moved to
/// another device: a backup restored on a new iPhone has no contacts.
struct KeychainContactVault: ContactVault {
    static let defaultAccount = "one.monero.contacts"
    let account: String

    init(account: String = KeychainContactVault.defaultAccount) {
        self.account = account
    }

    func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data?) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(match as CFDictionary)
        guard let data else { return }
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// The saved contacts. Remove All wipes them (`WalletManager.deleteAllWallets`).
@MainActor
final class ContactStore: ObservableObject {
    static let shared = ContactStore()

    /// A to Z by name.
    @Published private(set) var contacts: [Contact] = []

    private let vault: ContactVault

    init(vault: ContactVault = KeychainContactVault()) {
        self.vault = vault
        contacts = Self.sorted(Self.decode(vault.read()))
    }

    @discardableResult
    func add(name: String, destination: String) -> Contact {
        let contact = Contact(name: Self.clean(name), destination: Self.clean(destination))
        save(contacts + [contact])
        return contact
    }

    /// Saves a changed name or destination. The kind follows the destination.
    func update(_ contact: Contact) {
        var changed = contact
        changed.name = Self.clean(contact.name)
        changed.destination = Self.clean(contact.destination)
        changed.kind = Contact.kind(of: changed.destination)
        save(contacts.map { $0.id == contact.id ? changed : $0 })
    }

    func delete(id: UUID) {
        save(contacts.filter { $0.id != id })
    }

    func contact(id: UUID) -> Contact? {
        contacts.first { $0.id == id }
    }

    func clearAll() {
        vault.write(nil)
        contacts = []
    }

    private func save(_ list: [Contact]) {
        contacts = Self.sorted(list)
        vault.write(try? JSONEncoder().encode(contacts))
    }

    private static func decode(_ data: Data?) -> [Contact] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Contact].self, from: data)) ?? []
    }

    static func sorted(_ list: [Contact]) -> [Contact] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Finds contacts for Send's field, the sheet's search and History.
enum ContactMatch {
    /// Contacts whose name or destination holds the text, in any case.
    static func matches(_ text: String, in contacts: [Contact]) -> [Contact] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.destination.localizedCaseInsensitiveContains(query)
        }
    }

    /// The contact saved with this address.
    static func contact(forAddress address: String, in contacts: [Contact]) -> Contact? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return contacts.first { $0.kind == .address && $0.destination == trimmed }
    }

    /// The contact saved with this OpenAlias name, in any case.
    static func contact(forOpenAlias name: OpenAliasName, in contacts: [Contact]) -> Contact? {
        contacts.first { $0.openAliasName?.query == name.query }
    }

    /// The contact for the text in Send's field: its address, or its
    /// OpenAlias name.
    static func contact(forInput text: String, in contacts: [Contact]) -> Contact? {
        switch OpenAlias.classify(text) {
        case .address(let address): return contact(forAddress: address, in: contacts)
        case .name(let name): return contact(forOpenAlias: name, in: contacts)
        case .empty, .reserved, .invalidName: return nil
        }
    }
}
