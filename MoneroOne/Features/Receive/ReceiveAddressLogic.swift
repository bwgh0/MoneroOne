import Foundation
import MoneroKit

/// What one receiving address has taken in, from the transaction list:
/// incoming payments, pool included, failed ones left out.
struct ReceiveAddressUsage: Equatable {
    var payments: Int = 0
    var received: Decimal = 0
}

/// One address as the Receive card and the address list show it.
struct ReceiveAddressRow: Identifiable, Equatable {
    let index: Int
    let address: String
    let label: String
    var usage = ReceiveAddressUsage()

    var id: Int { index }
    var isMain: Bool { index == 0 }
    var isUsed: Bool { usage.payments > 0 }
    var isLabeled: Bool { !label.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The one name every screen uses: the label, else "Subaddress #index".
    var name: String { SubaddressName.display(index: index, label: label) }
}

/// An entry in the address list: an address, or a run of unused spares
/// folded into one row.
enum ReceiveAddressListItem: Identifiable, Equatable {
    case address(ReceiveAddressRow)
    /// Newest first, like the list around it.
    case unusedRun([ReceiveAddressRow])

    var id: String {
        switch self {
        case .address(let row): return "address-\(row.index)"
        case .unusedRun(let rows): return "run-\(rows.first?.index ?? 0)"
        }
    }
}

enum ReceiveAddressLogic {
    /// A wallet restored from its seed finds payments only this many
    /// subaddresses past the last used one (wallet2's minor lookahead).
    static let seedRestoreLookahead = 200
    /// New Address warns from this many unused addresses after the last
    /// used one, and stops at `unusedStopThreshold`.
    static let unusedWarningThreshold = 150
    static let unusedStopThreshold = 190
    /// Shorter runs of unused spares stay unfolded: folding two rows into
    /// one saves little and hides what is there.
    static let minimumFoldedRun = 3
    /// The list shows its search field above this many addresses.
    static let searchThreshold = 8

    // MARK: Rows

    /// Incoming payments and amounts per receiving address.
    static func usage(transactions: [MoneroTransaction]) -> [String: ReceiveAddressUsage] {
        var usage: [String: ReceiveAddressUsage] = [:]
        for tx in transactions where tx.type == .incoming && tx.status != .failed && !tx.address.isEmpty {
            usage[tx.address, default: ReceiveAddressUsage()].payments += 1
            usage[tx.address, default: ReceiveAddressUsage()].received += tx.amount
        }
        return usage
    }

    /// The wallet's subaddresses (index above 0) with a real address,
    /// newest first. The main address is `mainRow(primaryAddress:usage:)`.
    static func subaddressRows(
        _ subaddresses: [SubaddressSummary],
        usage: [String: ReceiveAddressUsage]
    ) -> [ReceiveAddressRow] {
        var seen = Set<Int>()
        return subaddresses
            .filter { $0.index > 0 && !$0.address.isEmpty && !NullKeyAddress.isNullKey($0.address) }
            .sorted { $0.index > $1.index }
            .filter { seen.insert($0.index).inserted }
            .map { ReceiveAddressRow(index: $0.index, address: $0.address, label: $0.label, usage: usage[$0.address] ?? ReceiveAddressUsage()) }
    }

    /// The main address row, nil until the wallet has one (never the
    /// null-key address).
    static func mainRow(primaryAddress: String, usage: [String: ReceiveAddressUsage]) -> ReceiveAddressRow? {
        guard !primaryAddress.isEmpty, !NullKeyAddress.isNullKey(primaryAddress) else { return nil }
        return ReceiveAddressRow(index: 0, address: primaryAddress, label: "", usage: usage[primaryAddress] ?? ReceiveAddressUsage())
    }

    // MARK: List

    /// The subaddress section of the list: newest first, with runs of
    /// unused, unnamed addresses folded into one row. Only runs below the
    /// newest used or named address fold: the spares wallet2 fills in
    /// between payments. Addresses above it are the ones the user just
    /// made, and the selected address always shows.
    static func listItems(
        _ rows: [ReceiveAddressRow],
        selectedIndex: Int,
        expandedRuns: Set<Int> = []
    ) -> [ReceiveAddressListItem] {
        let newestReserved = rows.first { $0.isUsed || $0.isLabeled }?.index ?? Int.max
        var items: [ReceiveAddressListItem] = []
        var run: [ReceiveAddressRow] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= minimumFoldedRun, let top = run.first, !expandedRuns.contains(top.index) {
                items.append(.unusedRun(run))
            } else {
                items.append(contentsOf: run.map { .address($0) })
            }
            run = []
        }

        for row in rows {
            let foldable = row.index < newestReserved && !row.isUsed && !row.isLabeled && row.index != selectedIndex
            if foldable {
                run.append(row)
            } else {
                flushRun()
                items.append(.address(row))
            }
        }
        flushRun()
        return items
    }

    /// The address cards in order: the main address pinned first, then
    /// `listItems`; while searching, every match unfolded.
    static func stackItems(
        main: ReceiveAddressRow?,
        rows: [ReceiveAddressRow],
        selectedIndex: Int,
        expandedRuns: Set<Int> = [],
        search: String = ""
    ) -> [ReceiveAddressListItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var items: [ReceiveAddressListItem] = []
        if let main, matches(main, search: query) {
            items.append(.address(main))
        }
        if query.isEmpty {
            items += listItems(rows, selectedIndex: selectedIndex, expandedRuns: expandedRuns)
        } else {
            items += rows.filter { matches($0, search: query) }.map { .address($0) }
        }
        return items
    }

    /// The search field shows from nine addresses, the main one included.
    static func showsSearch(addressCount: Int) -> Bool {
        addressCount > searchThreshold
    }

    /// The label a rename saves, or nil when nothing changes. The field
    /// starts with the current label, empty for an unnamed address, so
    /// saving it untouched never turns "Subaddress #n" into a label (a
    /// label reserves the address).
    static func labelToSave(draft: String, current: String) -> String? {
        let new = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return new == old ? nil : new
    }

    /// Search by name, "#index" or any part of the address.
    static func matches(_ row: ReceiveAddressRow, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if row.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        if let wanted = Int(number), wanted == row.index { return true }
        return row.address.range(of: query, options: .caseInsensitive) != nil
    }

    // MARK: Seed-restore lookahead

    /// Subaddresses after the last used one (the main address counts as
    /// used): the run a seed restore must look across. New addresses
    /// extend it; a payment to any of them resets it.
    static func unusedAfterLastUsed(_ rows: [ReceiveAddressRow]) -> Int {
        guard let highest = rows.map(\.index).max() else { return 0 }
        let lastUsed = rows.filter(\.isUsed).map(\.index).max() ?? 0
        return max(0, highest - lastUsed)
    }

    enum CreationLimit: Equatable {
        case allowed
        /// Allowed, with a warning: a seed restore may start missing
        /// payments soon.
        case warn(unused: Int)
        /// New Address is off until one of the unused addresses is paid.
        case stop(unused: Int)
    }

    static func creationLimit(unusedAfterLastUsed unused: Int) -> CreationLimit {
        if unused >= unusedStopThreshold { return .stop(unused: unused) }
        if unused >= unusedWarningThreshold { return .warn(unused: unused) }
        return .allowed
    }

    // MARK: Status line

    /// What the card says about the address it shows: always what happens
    /// after the next payment.
    enum Status: Equatable {
        /// The main address: payments to it can be linked.
        case mainAddress
        /// Rotation's pick: after a payment Receive moves to a new one.
        case unusedRotates
        /// Rotation on, the user's own pick (New Address or the list),
        /// no payment yet.
        case unusedShownUntilPaid
        /// Rotation on, the user's own pick of an address already paid.
        case usedShownUntilNextPayment(payments: Int)
        /// Rotation on, paid, not the user's pick: Receive is about to
        /// move on.
        case usedRotates
        /// Rotation off: Receive stays here.
        case stays(payments: Int)
    }

    static func status(for row: ReceiveAddressRow, rotate: Bool, isManualPick: Bool) -> Status {
        if row.isMain { return .mainAddress }
        guard rotate else { return .stays(payments: row.usage.payments) }
        switch (row.isUsed, isManualPick) {
        case (false, true): return .unusedShownUntilPaid
        case (false, false): return .unusedRotates
        case (true, true): return .usedShownUntilNextPayment(payments: row.usage.payments)
        case (true, false): return .usedRotates
        }
    }

    static func statusText(_ status: Status) -> String {
        switch status {
        case .mainAddress:
            return String(localized: "Payments to your main address can be linked together.", comment: "Receive card: status line when the main address is shown")
        case .unusedRotates:
            return String(localized: "Unused. After a payment, Receive shows a new address.", comment: "Receive card: status line, Fresh Receive Address on")
        case .unusedShownUntilPaid:
            return String(localized: "Unused. Shown until it gets paid.", comment: "Receive card: status line for an address the user picked or created")
        case .usedShownUntilNextPayment(let payments):
            return String(localized: "\(payments) payments so far. Shown until the next one.", comment: "Receive card: status line for a picked address that was already paid")
        case .usedRotates:
            return String(localized: "Paid. Receive shows a new address next.", comment: "Receive card: status line right after the shown address gets paid")
        case .stays(let payments):
            if payments == 0 {
                return String(localized: "Unused. Receive stays on this address.", comment: "Receive card: status line, Fresh Receive Address off")
            }
            return String(localized: "\(payments) payments so far. Receive stays on this address.", comment: "Receive card: status line, Fresh Receive Address off, address already paid")
        }
    }

    /// The card's warning or stop line for the seed-restore lookahead.
    static func limitText(_ limit: CreationLimit) -> String? {
        switch limit {
        case .allowed:
            return nil
        case .warn(let unused):
            return String(localized: "\(unused) unused addresses in a row. A restore from the seed finds payments only up to 200 past the last used one.", comment: "Receive card: warning under New Address")
        case .stop:
            return String(localized: "Use one of your unused addresses first. A restore from the seed would miss payments to new ones.", comment: "Receive card: New Address is off because too many addresses are unused")
        }
    }

    // MARK: Text helpers

    /// "8BNm4Pq2Za7k…9QmTZ1kq": the first and last characters, for list rows.
    static func shortAddress(_ address: String, head: Int = 12, tail: Int = 8) -> String {
        guard address.count > head + tail + 4 else { return address }
        return "\(address.prefix(head))…\(address.suffix(tail))"
    }

    /// The card's VoiceOver summary: name, number when the name is a
    /// label, status, and how the address starts and ends. The whole
    /// address waits on the More Content rotor.
    static func spokenSummary(for row: ReceiveAddressRow, status: String) -> String {
        let name = row.isLabeled && !row.isMain
            ? String(localized: "\(row.name), subaddress \(row.index)", comment: "VoiceOver: a named subaddress and its number")
            : row.name
        var parts = [name + ".", status]
        if row.address.count > 10 {
            parts.append(String(localized: "Address starts \(String(row.address.prefix(6))), ends \(String(row.address.suffix(4))).", comment: "VoiceOver: the first 6 and last 4 characters of an address"))
        }
        return parts.joined(separator: " ")
    }

    /// "3 payments", pluralized per language.
    static func paymentCount(_ payments: Int) -> String {
        String(localized: "\(payments) payments", comment: "Address list: how many payments an address received")
    }

    /// A list row for VoiceOver: "Gifts, subaddress 12, received 1.5 XMR,
    /// 3 payments". The Selected trait marks the shown address.
    static func spokenRow(_ row: ReceiveAddressRow) -> String {
        var parts: [String] = []
        if row.isLabeled && !row.isMain {
            parts.append(String(localized: "\(row.name), subaddress \(row.index)", comment: "VoiceOver: a named subaddress and its number"))
        } else {
            parts.append(row.name)
        }
        if row.isMain {
            parts.append(String(localized: "links payments together", comment: "VoiceOver: the main address row's warning"))
        }
        if row.isUsed {
            parts.append(String(localized: "received \(XMRFormatter.formatCompact(row.usage.received)) XMR", comment: "VoiceOver: an address list row's total"))
            parts.append(paymentCount(row.usage.payments))
        } else {
            parts.append(String(localized: "unused", comment: "VoiceOver: an address with no payments yet"))
        }
        return parts.joined(separator: ", ")
    }
}
