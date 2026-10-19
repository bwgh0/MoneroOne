import XCTest
import Security
@testable import MoneroOne

/// Send To, phase B: the contact store, the matches and History's names.
@MainActor
final class ContactStoreTests: XCTestCase {
    private final class MemoryVault: ContactVault {
        var data: Data?
        func read() -> Data? { data }
        func write(_ data: Data?) { self.data = data }
    }

    private let address = "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"
    private let otherAddress = "8BxsAvKW3NJ4MWj9hUuV8rJb5ifMRgRCbVhxJ7APrDNVSfKcU1Hbz7HnKMAUtsAAJLCbrUy6fTdyHHEZn9tt5hsGQ8PwqCq"

    // MARK: - Store

    func testAddEditAndDeleteKeepTheListAToZ() {
        let vault = MemoryVault()
        let store = ContactStore(vault: vault)
        let tomas = store.add(name: " Tomás ", destination: address)
        store.add(name: "ben", destination: "ben@example.org")
        store.add(name: "Alexandra", destination: otherAddress)

        XCTAssertEqual(store.contacts.map(\.name), ["Alexandra", "ben", "Tomás"])
        XCTAssertEqual(tomas.kind, .address)
        XCTAssertEqual(store.contacts[1].kind, .openAlias)

        var edited = tomas
        edited.name = "Dana"
        edited.destination = "dana@example.org"
        store.update(edited)
        XCTAssertEqual(store.contacts.map(\.name), ["Alexandra", "ben", "Dana"])
        XCTAssertEqual(store.contact(id: tomas.id)?.kind, .openAlias, "The kind follows the destination")

        store.delete(id: tomas.id)
        XCTAssertNil(store.contact(id: tomas.id))

        let reopened = ContactStore(vault: vault)
        XCTAssertEqual(reopened.contacts.map(\.name), ["Alexandra", "ben"], "The list survives a relaunch")
    }

    func testClearAllEmptiesTheVault() {
        let vault = MemoryVault()
        let store = ContactStore(vault: vault)
        store.add(name: "Dana", destination: address)

        store.clearAll()

        XCTAssertTrue(store.contacts.isEmpty)
        XCTAssertNil(vault.data)
    }

    /// A username contact (a later kind) must not need a migration: the
    /// fields decode as they are.
    func testContactDecodesItsFields() throws {
        let contact = Contact(name: "Dana", destination: address)
        let data = try JSONEncoder().encode([contact])
        XCTAssertEqual(try JSONDecoder().decode([Contact].self, from: data), [contact])
    }

    // MARK: - Keychain

    func testKeychainRoundTripIsThisDeviceOnly() throws {
        let vault = KeychainContactVault(account: "one.monero.contacts.tests")
        defer { vault.write(nil) }
        let payload = Data("contacts".utf8)

        vault.write(payload)
        XCTAssertEqual(vault.read(), payload)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: vault.account,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "Never moved to another device by a backup")

        vault.write(Data("second".utf8))
        XCTAssertEqual(vault.read(), Data("second".utf8), "A save replaces the item")

        vault.write(nil)
        XCTAssertNil(vault.read())
    }

    // MARK: - Matches

    func testTypingMatchesNameOrDestinationInAnyCase() {
        let dana = Contact(name: "Dana Okafor", destination: address)
        let ben = Contact(name: "Ben Carter", destination: "ben@example.org")
        let contacts = [ben, dana]

        XCTAssertEqual(ContactMatch.matches("da", in: contacts), [dana])
        XCTAssertEqual(ContactMatch.matches("EXAMPLE.ORG", in: contacts), [ben])
        XCTAssertEqual(ContactMatch.matches("4adund", in: contacts), [dana])
        XCTAssertEqual(ContactMatch.matches("  ", in: contacts), [])
        XCTAssertEqual(ContactMatch.matches("zed", in: contacts), [])
    }

    func testAPastedAddressTurnsIntoTheContactsCard() {
        let dana = Contact(name: "Dana", destination: address)
        let ben = Contact(name: "Ben", destination: "Ben@Example.org")

        XCTAssertEqual(ContactMatch.contact(forInput: " \(address)\n", in: [dana, ben]), dana)
        XCTAssertEqual(ContactMatch.contact(forInput: "ben@example.org", in: [dana, ben]), ben, "Names match in any case")
        XCTAssertNil(ContactMatch.contact(forInput: otherAddress, in: [dana, ben]))
        XCTAssertNil(ContactMatch.contact(forInput: "da", in: [dana, ben]), "Only a whole address or name gives the card")
    }

    // MARK: - History names

    private func sent(_ id: String, to destination: String) -> MoneroTransaction {
        MoneroTransaction(id: id, type: .outgoing, amount: 1, fee: Decimal(string: "0.001")!, address: destination,
                          timestamp: Date(timeIntervalSince1970: 1), confirmations: 20, status: .confirmed, memo: nil,
                          blockHeight: 1, destinations: [MoneroTransactionDestination(address: destination, amount: 1)])
    }

    private func namer(contacts: [Contact], aliases: [String: OpenAliasName] = [:]) -> ActivityNamer {
        ActivityNamer(records: [:], activeWalletId: UUID(), wallets: [], contacts: contacts, aliasNames: aliases)
    }

    func testHistoryNamesASendToAContact() {
        let dana = Contact(name: "Dana", destination: address)
        let name = namer(contacts: [dana]).name(of: sent("t1", to: address))

        XCTAssertEqual(name?.title, "To Dana")
        XCTAssertEqual(name?.badgeSymbol, ActivityNamer.contactBadgeSymbol)
    }

    func testHistoryNamesAnOpenAliasSendByItsContactOrItsName() {
        let ben = OpenAliasName(display: "ben@example.org", query: "ben.example.org")
        let aliases = [otherAddress: ben]

        let saved = namer(contacts: [Contact(name: "Ben Carter", destination: "ben@example.org")], aliases: aliases)
        XCTAssertEqual(saved.name(of: sent("t2", to: otherAddress))?.title, "To Ben Carter")

        let unsaved = namer(contacts: [], aliases: aliases).name(of: sent("t2", to: otherAddress))
        XCTAssertEqual(unsaved?.title, "To ben@example.org")
        XCTAssertNil(unsaved?.badgeSymbol, "An OpenAlias name that is not a contact has no badge")
    }

    func testAfterADeleteTheRowReadsSentAgain() {
        XCTAssertNil(namer(contacts: []).name(of: sent("t3", to: address)))
        XCTAssertNil(namer(contacts: [Contact(name: "Dana", destination: otherAddress)]).name(of: sent("t3", to: address)))
    }

    func testAWalletNameWinsOverAContact() {
        let me = UUID()
        let savings = WalletInfo(id: UUID(), name: "Savings", source: .seed(.bip39), createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                                 userCreatedSubaddressIndices: [], cachedPrimaryAddress: address, cachedBalance: nil)
        let namer = ActivityNamer(
            records: ["t4": SendRecord(txid: "t4", fromWalletId: me, toWalletId: savings.id)],
            activeWalletId: me,
            wallets: [savings],
            contacts: [Contact(name: "Dana", destination: address)]
        )
        XCTAssertEqual(namer.name(of: sent("t4", to: address))?.title, "To Savings")
    }

    func testSearchFindsAContactsRow() {
        let namer = namer(contacts: [Contact(name: "Dana", destination: address)])
        let tx = sent("t5", to: address)
        let rows = TransactionListLogic.filter([tx], type: .all, receivingIndex: nil, search: "dana",
                                               name: { ActivityRowText.searchName(of: $0, namer: namer, linkRecords: []) })
        XCTAssertEqual(rows.map(\.id), ["t5"])
    }

    // MARK: - Pins

    func testPinsGiveTheLatestNamePerAddress() {
        let suite = "ContactStoreTests.pins"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = OpenAliasPinStore(defaults: defaults)

        pins.record(query: "old.example.org", address: address, network: .mainnet, at: Date(timeIntervalSince1970: 10))
        pins.record(query: "ben.example.org", address: address, network: .mainnet, display: "ben@example.org", at: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(pins.names(network: .mainnet)[address], OpenAliasName(display: "ben@example.org", query: "ben.example.org"))
        XCTAssertTrue(pins.names(network: .testnet).isEmpty)
    }
}
