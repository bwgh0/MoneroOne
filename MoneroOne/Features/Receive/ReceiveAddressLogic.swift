import Foundation
import MoneroKit

/// What one receiving address has taken in, from the transaction list:
/// incoming payments, pool included, failed ones left out.
struct ReceiveAddressUsage: Equatable {
    var payments: Int = 0
    var received: Decimal = 0
}

/// One subaddress and what it has taken in.
struct ReceiveAddressRow: Equatable {
    let index: Int
    let address: String
    let label: String
    var usage = ReceiveAddressUsage()

    var isUsed: Bool { usage.payments > 0 }
}

/// The seed-restore limit on New: how many unused subaddresses a wallet
/// may run ahead of its last payment.
enum ReceiveAddressLogic {
    /// A wallet restored from its seed finds payments only this many
    /// subaddresses past the last used one (wallet2's minor lookahead).
    static let seedRestoreLookahead = 200
    /// New warns from this many unused addresses after the last used one,
    /// and stops at `unusedStopThreshold`.
    static let unusedWarningThreshold = 150
    static let unusedStopThreshold = 190

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
