import Foundation
import MoneroKit

/// What one receiving address has taken in, from the transaction list:
/// incoming payments, pool included, failed ones left out.
struct ReceiveAddressUsage: Equatable {
    var payments: Int = 0
    var received: Decimal = 0
}

/// One address and what it has taken in.
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

/// An entry in Select Address: an address, or a run of unused spares
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

/// What each receiving address has taken in, and the seed-restore limit on
/// New: how many unused subaddresses a wallet may run ahead of its last
/// payment.
enum ReceiveAddressLogic {
    /// A wallet restored from its seed finds payments only this many
    /// subaddresses past the last used one (wallet2's minor lookahead).
    static let seedRestoreLookahead = 200
    /// New warns from this many unused addresses after the last used one,
    /// and stops at `unusedStopThreshold`.
    static let unusedWarningThreshold = 150
    static let unusedStopThreshold = 190
    /// Shorter runs of unused spares stay unfolded: folding two rows into
    /// one saves little and hides what is there.
    static let minimumFoldedRun = 3

    /// Incoming payments and amounts per receiving address.
    static func usage(transactions: [MoneroTransaction]) -> [String: ReceiveAddressUsage] {
        var usage: [String: ReceiveAddressUsage] = [:]
        for tx in transactions where tx.type == .incoming && tx.status != .failed && !tx.address.isEmpty {
            usage[tx.address, default: ReceiveAddressUsage()].payments += 1
            usage[tx.address, default: ReceiveAddressUsage()].received += tx.amount
        }
        return usage
    }

    /// What one address has taken in.
    static func usage(of address: String, transactions: [MoneroTransaction]) -> ReceiveAddressUsage {
        var usage = ReceiveAddressUsage()
        guard !address.isEmpty else { return usage }
        for tx in transactions where tx.type == .incoming && tx.status != .failed && tx.address == address {
            usage.payments += 1
            usage.received += tx.amount
        }
        return usage
    }

    /// "3 payments", pluralized per language.
    static func paymentCount(_ payments: Int) -> String {
        String(localized: "\(payments) payments", comment: "Address list: how many payments an address received")
    }

    /// An address's usage for VoiceOver: "received 1.5000 XMR, 3 payments",
    /// or "unused".
    static func spokenUsage(_ usage: ReceiveAddressUsage) -> String {
        guard usage.payments > 0 else {
            return String(localized: "unused", comment: "VoiceOver: an address with no payments yet")
        }
        return [
            String(localized: "received \(XMRFormatter.formatCompact(usage.received)) XMR", comment: "VoiceOver: total received"),
            paymentCount(usage.payments),
        ].joined(separator: ", ")
    }

    /// The wallet's subaddresses (index above 0) with a real address,
    /// newest first.
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

    /// The subaddress section of Select Address: newest first, with runs of
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

    /// "86pBXYCQ…RJMUzQWi": the first and last eight characters.
    static func shortAddress(_ address: String, head: Int = 8, tail: Int = 8) -> String {
        guard address.count > head + tail + 4 else { return address }
        return "\(address.prefix(head))…\(address.suffix(tail))"
    }

    /// A row for VoiceOver: "Gifts, subaddress 12, received 1.5000 XMR,
    /// 3 payments". The Selected trait marks the shown address.
    static func spokenRow(_ row: ReceiveAddressRow) -> String {
        let name = row.isLabeled && !row.isMain
            ? String(localized: "\(row.name), subaddress \(row.index)", comment: "VoiceOver: a named subaddress and its number")
            : row.name
        return [name, spokenUsage(row.usage)].joined(separator: ", ")
    }

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
        /// New is off until one of the unused addresses is paid.
        case stop(unused: Int)
    }

    static func creationLimit(unusedAfterLastUsed unused: Int) -> CreationLimit {
        if unused >= unusedStopThreshold { return .stop(unused: unused) }
        if unused >= unusedWarningThreshold { return .warn(unused: unused) }
        return .allowed
    }

    /// The limit for a wallet. Below `unusedWarningThreshold` subaddresses
    /// no run can reach it, so the transactions are read only past that.
    static func creationLimit(subaddresses: [SubaddressSummary], transactions: [MoneroTransaction]) -> CreationLimit {
        guard let highest = subaddresses.map(\.index).max(), highest >= unusedWarningThreshold else {
            return .allowed
        }
        let rows = subaddressRows(subaddresses, usage: usage(transactions: transactions))
        return creationLimit(unusedAfterLastUsed: unusedAfterLastUsed(rows))
    }

    /// The warning or stop line under New for the seed-restore lookahead.
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
}
