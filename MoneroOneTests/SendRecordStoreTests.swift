import XCTest
@testable import MoneroOne

/// Send To, phase A: the send records behind History's wallet names, the
/// own-address rule, the address-to-wallet match and Transfer's To rows.
final class SendRecordStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SendRecordStore!
    private let suite = "SendRecordStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = SendRecordStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func wallet(_ name: String, address: String?) -> WalletInfo {
        WalletInfo(id: UUID(), name: name, source: .seed(.bip39), createdAt: Date(), restoreHeight: 0, syncResetCount: 0,
                   userCreatedSubaddressIndices: [], cachedPrimaryAddress: address, cachedBalance: nil)
    }

    // MARK: - Store

    func testRecordIsFoundByTxidInAnyCase() {
        let a = UUID(), b = UUID()
        store.record(SendRecord(txid: "ABCDEF01", fromWalletId: a, toWalletId: b))

        XCTAssertEqual(store.record(txid: "abcdef01")?.fromWalletId, a)
        XCTAssertEqual(store.record(txid: "ABCDEF01")?.toWalletId, b)
        XCTAssertNil(store.record(txid: "other"))
    }

    func testRemovingAWalletRemovesEveryRecordThatNamesIt() {
        let a = UUID(), b = UUID(), c = UUID()
        store.record(SendRecord(txid: "t1", fromWalletId: a, toWalletId: b))
        store.record(SendRecord(txid: "t2", fromWalletId: b, toWalletId: c))
        store.record(SendRecord(txid: "t3", fromWalletId: c, toWalletId: a))

        store.removeRecords(naming: b)

        XCTAssertNil(store.record(txid: "t1"))
        XCTAssertNil(store.record(txid: "t2"))
        XCTAssertNotNil(store.record(txid: "t3"))
    }

    func testClearAllEmptiesTheStore() {
        store.record(SendRecord(txid: "t1", fromWalletId: UUID(), toWalletId: UUID()))
        store.clearAll()
        XCTAssertNil(store.record(txid: "t1"))
    }

    /// Phase B adds contacts and typed names: a record from before that
    /// still decodes, and one with them decodes here.
    func testRecordDecodesWithAndWithoutTheLaterFields() throws {
        let a = UUID()
        let old = #"{"t1":{"txid":"t1","fromWalletId":"\#(a.uuidString)","createdAt":1}}"#
        defaults.set(Data(old.utf8), forKey: SendRecordStore.key)
        XCTAssertEqual(store.record(txid: "t1")?.fromWalletId, a)
        XCTAssertNil(store.record(txid: "t1")?.toWalletId)

        let contact = UUID()
        store.record(SendRecord(txid: "t2", fromWalletId: a, contactId: contact, recipient: "kaito@monero.one"))
        XCTAssertEqual(store.record(txid: "t2")?.contactId, contact)
        XCTAssertEqual(store.record(txid: "t2")?.recipient, "kaito@monero.one")
    }

    // MARK: - Names

    func testOutgoingToAnotherWalletIsNamedByThatWalletsCurrentName() {
        var savings = wallet("Savings", address: "4s")
        let spending = wallet("Spending", address: "4p")
        let record = SendRecord(txid: "t", fromWalletId: spending.id, toWalletId: savings.id)

        XCTAssertEqual(WalletTransferName.resolve(record: record, isIncoming: false, amount: 1, fee: 0.0001,
                                                  activeWalletId: spending.id, wallets: [spending, savings])?.title,
                       "To Savings")
        savings.name = "Rainy Day"
        XCTAssertEqual(WalletTransferName.resolve(record: record, isIncoming: false, amount: 1, fee: 0.0001,
                                                  activeWalletId: spending.id, wallets: [spending, savings])?.title,
                       "To Rainy Day", "A renamed wallet shows its new name")
    }

    func testIncomingFromAnotherWalletIsNamedFromIt() {
        let savings = wallet("Savings", address: "4s")
        let spending = wallet("Spending", address: "4p")
        let record = SendRecord(txid: "t", fromWalletId: spending.id, toWalletId: savings.id)

        XCTAssertEqual(WalletTransferName.resolve(record: record, isIncoming: true, amount: 1, fee: 0,
                                                  activeWalletId: savings.id, wallets: [spending, savings]),
                       .from(spending))
    }

    func testRecordOfARemovedWalletGivesNoName() {
        let spending = wallet("Spending", address: "4p")
        let record = SendRecord(txid: "t", fromWalletId: spending.id, toWalletId: UUID())

        XCTAssertNil(WalletTransferName.resolve(record: record, isIncoming: false, amount: 1, fee: 0.0001,
                                                activeWalletId: spending.id, wallets: [spending]))
    }

    func testOtherWalletsRecordGivesNoNameHere() {
        let a = wallet("A", address: "4a"), b = wallet("B", address: "4b"), c = wallet("C", address: "4c")
        let record = SendRecord(txid: "t", fromWalletId: a.id, toWalletId: b.id)

        XCTAssertNil(WalletTransferName.resolve(record: record, isIncoming: false, amount: 1, fee: 0.0001,
                                                activeWalletId: c.id, wallets: [a, b, c]))
    }

    func testSendToThisWalletByRecord() {
        let a = wallet("A", address: "4a")
        let record = SendRecord(txid: "t", fromWalletId: a.id, toWalletId: a.id)

        // Pending: wallet2 still shows the amount sent.
        XCTAssertEqual(WalletTransferName.resolve(record: record, isIncoming: false, amount: 2, fee: 0.0001,
                                                  activeWalletId: a.id, wallets: [a]),
                       .toThisWallet)
    }

    /// wallet2 books a send to the wallet's own account as an outgoing 0
    /// plus the fee: old sends, with no record, are named too.
    func testOutgoingZeroWithAFeeIsASendToThisWallet() {
        let a = wallet("A", address: "4a")
        XCTAssertEqual(WalletTransferName.resolve(record: nil, isIncoming: false, amount: 0, fee: 0.0001,
                                                  activeWalletId: a.id, wallets: [a]),
                       .toThisWallet)
        XCTAssertNil(WalletTransferName.resolve(record: nil, isIncoming: false, amount: 1, fee: 0.0001,
                                                activeWalletId: a.id, wallets: [a]))
        XCTAssertNil(WalletTransferName.resolve(record: nil, isIncoming: true, amount: 0, fee: 0,
                                                activeWalletId: a.id, wallets: [a]))
    }

    // MARK: - Address match

    func testAddressMatchesAWalletsSavedAddressOnly() {
        let a = wallet("A", address: "4aaa")
        let b = wallet("B", address: nil)

        XCTAssertEqual(WalletAddressMatch.wallet(for: " 4aaa\n", wallets: [a, b], activeWalletId: nil, activePrimaryAddress: "")?.id, a.id)
        XCTAssertNil(WalletAddressMatch.wallet(for: "4bbb", wallets: [a, b], activeWalletId: nil, activePrimaryAddress: ""),
                     "A wallet with no saved address is never guessed")
        XCTAssertNil(WalletAddressMatch.wallet(for: "", wallets: [a, b], activeWalletId: nil, activePrimaryAddress: ""))
    }

    func testAddressMatchesTheOpenWalletsLiveAddress() {
        let open = wallet("Open", address: nil)
        XCTAssertEqual(WalletAddressMatch.wallet(for: "4live", wallets: [open], activeWalletId: open.id, activePrimaryAddress: "4live")?.id, open.id)
    }

    // MARK: - Transfer To rows

    func testToRowStates() {
        let valid: (String) -> Bool = { $0.hasPrefix("4") }

        XCTAssertEqual(TransferDestinationState.of(savedAddress: "4abc", needsRestore: false, isValidAddress: valid), .ready(address: "4abc"))
        XCTAssertEqual(TransferDestinationState.of(savedAddress: nil, needsRestore: false, isValidAddress: valid), .needsOpen)
        XCTAssertEqual(TransferDestinationState.of(savedAddress: "xbad", needsRestore: false, isValidAddress: valid), .needsOpen,
                       "An address that fails Send's check is never used")
        XCTAssertEqual(TransferDestinationState.of(savedAddress: "4abc", needsRestore: true, isValidAddress: valid), .needsRestore)
    }
}
