import Foundation

/// Who a send went to, written on this iPhone when the send goes out. History
/// reads it to name the rows ("To Savings", "From Spending"). App-wide, not
/// per wallet: the other wallet looks up the same txid.
///
/// Names are looked up when a row shows, never stored here, so a renamed
/// wallet shows its new name.
struct SendRecord: Codable, Equatable {
    let txid: String
    /// The wallet that sent.
    let fromWalletId: UUID
    /// One of this iPhone's wallets that received, when it is one.
    var toWalletId: UUID?
    /// Later: a contact that received.
    var contactId: UUID?
    /// Later: a name the user typed (an OpenAlias name or a username).
    var recipient: String?
    /// Unix seconds.
    let createdAt: Int64

    init(txid: String, fromWalletId: UUID, toWalletId: UUID? = nil, contactId: UUID? = nil, recipient: String? = nil, createdAt: Date = Date()) {
        self.txid = txid
        self.fromWalletId = fromWalletId
        self.toWalletId = toWalletId
        self.contactId = contactId
        self.recipient = recipient
        self.createdAt = Int64(createdAt.timeIntervalSince1970)
    }
}

/// The send records, kept in UserDefaults next to the wallet list
/// (`WalletStore`), with the same rules: metadata only, no keys.
struct SendRecordStore {
    static let key = "one.monero.sendRecords"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ record: SendRecord) {
        let txid = record.txid.lowercased()
        guard !txid.isEmpty else { return }
        var records = load()
        records[txid] = record
        save(records)
    }

    func record(txid: String) -> SendRecord? {
        load()[txid.lowercased()]
    }

    /// Every record, keyed by lowercase txid: one read for a whole list.
    func allRecords() -> [String: SendRecord] {
        load()
    }

    /// A removed wallet takes its records with it: its rows, and the other
    /// wallet's rows, go back to "Sent" and "Received".
    func removeRecords(naming walletId: UUID) {
        let records = load()
        let kept = records.filter { $0.value.fromWalletId != walletId && $0.value.toWalletId != walletId }
        guard kept.count != records.count else { return }
        save(kept)
    }

    func clearAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func load() -> [String: SendRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([String: SendRecord].self, from: data) else { return [:] }
        return records
    }

    private func save(_ records: [String: SendRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The name an Activity row gets from a send between this iPhone's wallets.
enum WalletTransferName: Equatable {
    /// A send to this wallet's own address. The row shows the fee only.
    case toThisWallet
    case to(WalletInfo)
    case from(WalletInfo)

    var title: String {
        switch self {
        case .toThisWallet:
            return String(localized: "To This Wallet", comment: "Activity row: a send from this wallet to its own address")
        case .to(let wallet):
            return String(localized: "To \(wallet.name)", comment: "Activity row: a send to another of your wallets, by its name")
        case .from(let wallet):
            return String(localized: "From \(wallet.name)", comment: "Activity row: a transfer from another of your wallets, by its name")
        }
    }

    /// The row's name, or nil for a plain "Sent" or "Received".
    ///
    /// wallet2 books a send to the wallet's own account as an outgoing
    /// transfer of 0 plus the fee ("sending to yourself" in wallet2), so a
    /// confirmed outgoing 0 is a send to this wallet, also from before the
    /// record existed. Until it confirms, the record says so.
    static func resolve(
        record: SendRecord?,
        isIncoming: Bool,
        amount: Decimal,
        fee: Decimal,
        activeWalletId: UUID?,
        wallets: [WalletInfo]
    ) -> WalletTransferName? {
        guard let activeWalletId else { return nil }
        if let record {
            if isIncoming {
                if record.toWalletId == activeWalletId, record.fromWalletId != activeWalletId,
                   let from = wallets.first(where: { $0.id == record.fromWalletId }) {
                    return .from(from)
                }
            } else if record.fromWalletId == activeWalletId, let toId = record.toWalletId {
                if toId == activeWalletId { return .toThisWallet }
                if let to = wallets.first(where: { $0.id == toId }) { return .to(to) }
            }
        }
        if !isIncoming, amount == 0, fee > 0 { return .toThisWallet }
        return nil
    }
}

/// The name an Activity row shows in place of "Sent" or "Received", and
/// its badge. History search finds a row by this name too.
struct ActivityName: Equatable {
    let title: String
    /// The wallet or the person on the disc. Nil for an OpenAlias name.
    let badgeSymbol: String?
    /// A send to this wallet: the row shows only the fee.
    let showsFeeOnly: Bool
}

/// Names the rows of one list from one read of the stores: a send between
/// your wallets ("To Savings", "From Spending", "To This Wallet"), then a
/// send to a contact ("To Dana") or to an OpenAlias name ("To
/// ben@monero.one"). Names are looked up each time, so after a delete or a
/// rename the rows follow.
struct ActivityNamer {
    let records: [String: SendRecord]
    let activeWalletId: UUID?
    let wallets: [WalletInfo]
    var contacts: [Contact] = []
    /// The OpenAlias name last paid at each address (the pin store).
    var aliasNames: [String: OpenAliasName] = [:]

    /// The badge of a send between your wallets.
    static let walletBadgeSymbol = "wallet.bifold.fill"
    /// The badge of a send to a contact.
    static let contactBadgeSymbol = "person.fill"

    func name(of transaction: MoneroTransaction) -> ActivityName? {
        let isIncoming = transaction.type == .incoming
        if let transfer = WalletTransferName.resolve(
            record: records[transaction.id.lowercased()],
            isIncoming: isIncoming,
            amount: transaction.amount,
            fee: transaction.fee,
            activeWalletId: activeWalletId,
            wallets: wallets
        ) {
            return ActivityName(title: transfer.title, badgeSymbol: Self.walletBadgeSymbol, showsFeeOnly: transfer == .toThisWallet)
        }
        // wallet2 keeps the destination of each send this wallet built.
        guard !isIncoming, let address = transaction.destinations.first?.address ?? transaction.address.nilIfEmpty else { return nil }
        let alias = aliasNames[address]
        if let contact = ContactMatch.contact(forAddress: address, in: contacts)
            ?? alias.flatMap({ ContactMatch.contact(forOpenAlias: $0, in: contacts) }) {
            return ActivityName(
                title: String(localized: "To \(contact.name)", comment: "Activity row: a send to a saved contact, by its name"),
                badgeSymbol: Self.contactBadgeSymbol,
                showsFeeOnly: false
            )
        }
        if let alias {
            return ActivityName(
                title: String(localized: "To \(alias.display)", comment: "Activity row: a send to an OpenAlias name that is not a contact"),
                badgeSymbol: nil,
                showsFeeOnly: false
            )
        }
        return nil
    }
}

/// The wallet that Send's amount title and Review name: Transfer's pick,
/// or the wallet whose address is in Send's field. A payment link has none.
enum SendWalletRecipient {
    static func wallet(transferTarget: WalletInfo?, matched: WalletInfo?, isTransfer: Bool, isLinkMode: Bool) -> WalletInfo? {
        if let transferTarget { return transferTarget }
        guard !isTransfer, !isLinkMode else { return nil }
        return matched
    }
}

/// Finds which of this iPhone's wallets owns an address, by the primary
/// address each wallet saved when it was last open. A wallet that has not
/// saved one never matches: its address is never guessed.
enum WalletAddressMatch {
    static func wallet(
        for address: String,
        wallets: [WalletInfo],
        activeWalletId: UUID?,
        activePrimaryAddress: String
    ) -> WalletInfo? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return wallets.first { wallet in
            savedAddress(of: wallet, activeWalletId: activeWalletId, activePrimaryAddress: activePrimaryAddress) == trimmed
        }
    }

    /// The wallet's saved primary address: the open wallet's live one, else
    /// the one it saved when it was last open. Nil when there is none.
    static func savedAddress(of wallet: WalletInfo, activeWalletId: UUID?, activePrimaryAddress: String) -> String? {
        let address = wallet.id == activeWalletId && !activePrimaryAddress.isEmpty
            ? activePrimaryAddress
            : wallet.cachedPrimaryAddress
        guard let address, !address.isEmpty else { return nil }
        return address
    }
}

/// The state of one wallet under To on the Transfer sheet.
enum TransferDestinationState: Equatable {
    /// Tappable: a send goes to this saved, valid address.
    case ready(address: String)
    /// No saved primary address yet (not opened since the update), or one
    /// that does not pass Send's address check.
    case needsOpen
    /// The wallet's keys are not on this iPhone.
    case needsRestore

    static func of(savedAddress: String?, needsRestore: Bool, isValidAddress: (String) -> Bool) -> TransferDestinationState {
        if needsRestore { return .needsRestore }
        guard let savedAddress, isValidAddress(savedAddress) else { return .needsOpen }
        return .ready(address: savedAddress)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
