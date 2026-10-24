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

    // MARK: - Round 2 follow-ups

    private func sent(_ id: String, amount: Decimal, fee: Decimal, status: MoneroTransaction.TransactionStatus = .confirmed) -> MoneroTransaction {
        MoneroTransaction(id: id, type: .outgoing, amount: amount, fee: fee, address: "", timestamp: Date(timeIntervalSince1970: 1),
                          confirmations: status == .pending ? 0 : 20, status: status, memo: nil, blockHeight: status == .pending ? nil : 1)
    }

    /// Follow-up 1: the detail of a send to this wallet reads "To This
    /// Wallet" and shows only the fee, while pending and once confirmed.
    func testSendToThisWalletDetailShowsTheFeeOnly() {
        let me = UUID()
        let pending = sent("p1", amount: Decimal(string: "0.5")!, fee: Decimal(string: "0.0018")!, status: .pending)
        let confirmed = sent("c1", amount: 0, fee: Decimal(string: "0.0018")!)
        let record = SendRecord(txid: "p1", fromWalletId: me, toWalletId: me)

        let pendingName = WalletTransferName.resolve(record: record, isIncoming: false, amount: pending.amount, fee: pending.fee, activeWalletId: me, wallets: [])
        let confirmedName = WalletTransferName.resolve(record: nil, isIncoming: false, amount: confirmed.amount, fee: confirmed.fee, activeWalletId: me, wallets: [])

        XCTAssertEqual(TransactionDetailLogic.shownAmount(pending, transfer: pendingName), Decimal(string: "0.0018")!)
        XCTAssertEqual(TransactionDetailLogic.shownAmount(confirmed, transfer: confirmedName), Decimal(string: "0.0018")!)
        XCTAssertEqual(TransactionDetailLogic.title(pending, linkTitle: nil, transfer: pendingName), "To This Wallet")
        XCTAssertEqual(TransactionDetailLogic.title(confirmed, linkTitle: nil, transfer: confirmedName), "To This Wallet")

        let lines = TransactionDetailLogic.detailLines(transaction: pending, dateText: "d", receivedOnLabel: nil, receivedOnAddress: nil,
                                                       sentTo: [], txKey: nil, explorerURL: nil, transfer: pendingName)
        XCTAssertEqual(lines.first { $0.label == "Amount" }?.value.hasPrefix("-0.0018"), true)
        XCTAssertEqual(lines.first { $0.label == "Type" }?.value, "To This Wallet")
    }

    func testOtherSendsKeepTheirAmountAndTitle() {
        let other = wallet("Savings", address: "4savings")
        let tx = sent("t1", amount: 2, fee: Decimal(string: "0.001")!)
        let name = WalletTransferName.to(other)

        XCTAssertEqual(TransactionDetailLogic.shownAmount(tx, transfer: name), 2)
        XCTAssertEqual(TransactionDetailLogic.shownAmount(tx, transfer: nil), 2)
        XCTAssertEqual(TransactionDetailLogic.title(tx, linkTitle: nil, transfer: name), "Sent")
        XCTAssertEqual(TransactionDetailLogic.title(tx, linkTitle: "Dinner", transfer: nil), "Dinner")
    }

    /// Follow-up 2: the wallet whose address is in Send's field names the
    /// amount title and Review's To row, as Transfer's pick does.
    func testSendToYourWalletsAddressNamesTheWallet() {
        let savings = wallet("Savings", address: "4savings")
        let spending = wallet("Spending", address: "4spending")

        XCTAssertEqual(SendWalletRecipient.wallet(transferTarget: nil, matched: savings, isTransfer: false, isLinkMode: false), savings)
        XCTAssertEqual(SendWalletRecipient.wallet(transferTarget: spending, matched: nil, isTransfer: true, isLinkMode: false), spending)
        XCTAssertNil(SendWalletRecipient.wallet(transferTarget: nil, matched: savings, isTransfer: false, isLinkMode: true),
                     "A payment link has no wallet recipient")
        XCTAssertNil(SendWalletRecipient.wallet(transferTarget: nil, matched: nil, isTransfer: false, isLinkMode: false))
    }

    /// Transfer to This Wallet, or a Send to this wallet's own address:
    /// Review names To "This Wallet" and drops the Total row.
    func testTransferBackToThisWalletIsToSelf() {
        let spending = wallet("Spending", address: "4spending")
        let savings = wallet("Savings", address: "4savings")

        XCTAssertTrue(TransferParties(from: spending, fromAddress: "4spending", to: spending).isToSelf)
        XCTAssertFalse(TransferParties(from: spending, fromAddress: "4spending", to: savings).isToSelf)
    }

    /// Follow-up 3: History search finds a row by the name it shows.
    func testSearchFindsARowByItsWalletName() {
        let me = UUID()
        let savings = wallet("Savings", address: "4savings")
        let tx = sent("aa11", amount: 1, fee: Decimal(string: "0.001")!)
        let namer = ActivityNamer(
            records: ["aa11": SendRecord(txid: "aa11", fromWalletId: me, toWalletId: savings.id)],
            activeWalletId: me,
            wallets: [savings]
        )
        let name: (MoneroTransaction) -> String? = { ActivityRowText.searchName(of: $0, namer: namer, linkRecords: []) }

        XCTAssertEqual(name(tx), "To Savings")
        XCTAssertEqual(TransactionListLogic.filter([tx], type: .all, receivingIndex: nil, search: "savings", name: name).map(\.id), ["aa11"])
        XCTAssertEqual(TransactionListLogic.filter([tx], type: .all, receivingIndex: nil, search: "spending", name: name), [])
    }

    /// Follow-up 6: after Max, Sent shows what the transaction paid, not
    /// the balance in the field (the amount plus the fee).
    func testSentShowsTheAmountPaidAfterMax() {
        let paid = Decimal(string: "8.493784")!
        XCTAssertEqual(SentAmount.text(typed: "8.4963832", isSendingAll: true, sent: paid), "8.493784")
        XCTAssertEqual(SentAmount.text(typed: "1.5", isSendingAll: false, sent: Decimal(string: "1.5")!), "1.5")
        XCTAssertEqual(SentAmount.text(typed: "8.4963832", isSendingAll: true, sent: nil), "8.4963832",
                       "Before the send, or on a hardware wallet, the typed amount stays")
    }
}
