import SwiftUI
import MoneroKit

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var searchText = ""
    @State private var filterType: FilterType = .all
    /// Minor index of the receiving subaddress to show, nil for any.
    @State private var receivingIndex: Int?

    enum FilterType: String, CaseIterable {
        case all = "All"
        case incoming = "Received"
        case outgoing = "Sent"
        case pending = "Pending"
    }

    // For hardware-backed wallets, raw `transactions` is just
    // VIEW's read of incoming UTXOs — outgoing sends are
    // invisible to a watch-only key. Use `mergedTransactions`
    // which folds in the snapshot the hardware session writes
    // out (FULL wallet's tx list captured at the end of each
    // sync/send), so the All Transactions screen matches the
    // Recent list on the home view instead of mis-tagging
    // outgoing sends as Received.
    private var filteredTransactions: [MoneroTransaction] {
        TransactionListLogic.filter(
            walletManager.mergedTransactions,
            type: filterType,
            receivingIndex: receivingIndex,
            search: searchText
        )
    }

    private var receivingOptions: [ReceivingAddressOption] {
        TransactionListLogic.receivingAddressOptions(
            subaddresses: walletManager.subaddresses.map(SubaddressSummary.init),
            transactions: walletManager.mergedTransactions
        )
    }

    /// Display name of the active receiving-address filter, nil for "Any".
    private var receivingFilterName: String? {
        guard let receivingIndex else { return nil }
        return receivingOptions.first { $0.index == receivingIndex }?.name
            ?? SubaddressName.display(index: receivingIndex, label: "")
    }

    private var isFilterActive: Bool {
        filterType != .all || receivingIndex != nil
    }

    var body: some View {
        let filtered = filteredTransactions
        let totals = TransactionListLogic.totals(of: filtered)

        List {
            if filtered.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                summaryCard(totals)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(filtered) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
        .listStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: filtered.isEmpty)
        .navigationTitle("All Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .searchable(text: $searchText, prompt: "Search by ID, address, or memo")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .onChange(of: walletManager.primaryAddress) { _, _ in
            // Subaddress indices belong to one wallet; drop the
            // filter when the wallet underneath changes.
            receivingIndex = nil
        }
    }

    // MARK: - Filter menu

    private var filterMenu: some View {
        Menu {
            ForEach(FilterType.allCases, id: \.self) { type in
                Button {
                    filterType = type
                } label: {
                    HStack {
                        Text(type.rawValue)
                        if filterType == type {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Menu {
                Button {
                    receivingIndex = nil
                } label: {
                    HStack {
                        Text("Any")
                        if receivingIndex == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(receivingOptions) { option in
                    Button {
                        receivingIndex = option.index
                    } label: {
                        HStack {
                            Text(option.name)
                            if receivingIndex == option.index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label {
                    Text("Receiving address")
                    Text(receivingFilterName ?? "Any")
                } icon: {
                    Image(systemName: "arrow.down.left")
                }
            }
        } label: {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundColor(isFilterActive ? .orange : .primary)
        }
        .accessibilityLabel("Filter transactions")
        .accessibilityHint(filterAccessibilityHint)
    }

    private var filterAccessibilityHint: String {
        var hint = "Currently showing \(filterType.rawValue.lowercased()) transactions"
        if let receivingFilterName {
            hint += " on \(receivingFilterName)"
        }
        return hint
    }

    // MARK: - Summary card

    /// Totals for the rows on screen. Review-card style (radius 16,
    /// `secondarySystemBackground`) like the send review, since it is a
    /// table of amounts, not a hero.
    private func summaryCard(_ totals: TransactionTotals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TransactionListLogic.summaryTitle(
                count: totals.count,
                type: filterType,
                receivingName: receivingFilterName
            ))
            .font(.subheadline)
            .fontWeight(.semibold)
            .contentTransition(.numericText())

            HStack(alignment: .top, spacing: 16) {
                totalColumn(
                    title: "Received",
                    sign: "+",
                    amount: totals.received,
                    tint: .green
                )

                // Sends spend from the whole account, so a per-address
                // total would be meaningless; hide it under that filter.
                if receivingIndex == nil {
                    totalColumn(
                        title: "Sent",
                        sign: "-",
                        amount: totals.sent,
                        tint: .primary
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .animation(.easeInOut(duration: 0.2), value: totals)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel(totals))
    }

    private func totalColumn(title: String, sign: String, amount: Decimal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(sign)\(XMRFormatter.format(amount)) XMR")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let fiat = priceService.formatFiatValue(amount) {
                Text("≈ \(fiat)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryAccessibilityLabel(_ totals: TransactionTotals) -> String {
        var parts = [TransactionListLogic.summaryTitle(
            count: totals.count,
            type: filterType,
            receivingName: receivingFilterName
        )]
        var received = "received \(XMRFormatter.format(totals.received)) XMR"
        if let fiat = priceService.formatFiatValue(totals.received) {
            received += ", about \(fiat)"
        }
        parts.append(received)
        if receivingIndex == nil {
            var sent = "sent \(XMRFormatter.format(totals.sent)) XMR including fees"
            if let fiat = priceService.formatFiatValue(totals.sent) {
                sent += ", about \(fiat)"
            }
            parts.append(sent)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if !searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No results for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if let receivingFilterName {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No transactions on \(receivingFilterName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if filterType != .all {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No \(filterType.rawValue.lowercased()) transactions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No transactions yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - List logic (pure, covered by TransactionScreenLogicTests)

/// The part of `MoneroKit.SubAddress` the transaction screens read.
/// `SubAddress` is a GRDB record with an internal initializer, so the
/// pure functions take this value type and tests can build it.
struct SubaddressSummary: Hashable {
    let index: Int
    let address: String
    let label: String
    let transactionsCount: Int

    init(index: Int, address: String, label: String, transactionsCount: Int = 0) {
        self.index = index
        self.address = address
        self.label = label
        self.transactionsCount = transactionsCount
    }

    init(_ subaddress: MoneroKit.SubAddress) {
        self.init(
            index: subaddress.index,
            address: subaddress.address,
            label: subaddress.label,
            transactionsCount: subaddress.transactionsCount
        )
    }
}

/// One entry of the "Receiving address" filter submenu.
struct ReceivingAddressOption: Identifiable, Hashable {
    let index: Int
    let name: String
    var id: Int { index }
}

/// Totals of a set of transactions, failed ones left out.
struct TransactionTotals: Equatable {
    let count: Int
    let received: Decimal
    /// Amount plus fee of every outgoing transaction.
    let sent: Decimal

    static let empty = TransactionTotals(count: 0, received: 0, sent: 0)
}

enum SubaddressName {
    /// The name the receive picker gives a subaddress: "Main Address"
    /// for index 0, else the user's label with its emoji kept in front,
    /// else "Subaddress #n".
    static func display(index: Int, label: String) -> String {
        if index == 0 { return "Main Address" }
        let parts = splitSubaddressLabel(label)
        let name = parts.name.isEmpty ? "Subaddress #\(index)" : parts.name
        return joinSubaddressLabel(emoji: parts.emoji, name: name)
    }
}

extension WalletManager {
    /// The subaddress name VoiceOver speaks on a transaction row: the name
    /// of the subaddress an incoming transaction arrived on. Nil for sends
    /// and for the main address, so a wallet that uses one address keeps
    /// quiet rows. The detail screen always names the address.
    func receivedOnRowName(for tx: MoneroTransaction) -> String? {
        guard tx.type == .incoming else { return nil }
        let name = TransactionDetailLogic.receivedOnLabel(
            subaddressIndex: tx.subaddressIndex,
            address: tx.address,
            primaryAddress: primaryAddress,
            subaddresses: subaddresses.map(SubaddressSummary.init)
        )
        return name == SubaddressName.display(index: 0, label: "") ? nil : name
    }
}

enum TransactionListLogic {
    /// Type filter, receiving-address filter and search compose with AND.
    /// A receiving-address filter keeps incoming transactions only:
    /// sends spend from the account, not from one subaddress.
    static func matches(
        _ tx: MoneroTransaction,
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String
    ) -> Bool {
        switch type {
        case .all:
            break
        case .incoming:
            guard tx.type == .incoming else { return false }
        case .outgoing:
            guard tx.type == .outgoing else { return false }
        case .pending:
            guard tx.status == .pending else { return false }
        }

        if let receivingIndex {
            guard tx.type == .incoming, tx.subaddressIndex == receivingIndex else { return false }
        }

        if !search.isEmpty {
            let hit = tx.id.localizedCaseInsensitiveContains(search)
                || tx.address.localizedCaseInsensitiveContains(search)
                || (tx.memo?.localizedCaseInsensitiveContains(search) ?? false)
            guard hit else { return false }
        }

        return true
    }

    static func filter(
        _ transactions: [MoneroTransaction],
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String
    ) -> [MoneroTransaction] {
        transactions.filter { matches($0, type: type, receivingIndex: receivingIndex, search: search) }
    }

    /// Received and sent (amount plus fee) over `transactions`. Failed
    /// transactions moved nothing and are skipped; pending ones count.
    static func totals(of transactions: [MoneroTransaction]) -> TransactionTotals {
        var count = 0
        var received: Decimal = 0
        var sent: Decimal = 0
        for tx in transactions where tx.status != .failed {
            count += 1
            switch tx.type {
            case .incoming:
                received += tx.amount
            case .outgoing:
                sent += tx.amount + tx.fee
            }
        }
        return TransactionTotals(count: count, received: received, sent: sent)
    }

    /// "Main Address" first, then every real subaddress that has a
    /// label, a transaction count, or a transaction in the list. The
    /// unused unlabeled spares wallet2 pre-generates are left out.
    static func receivingAddressOptions(
        subaddresses: [SubaddressSummary],
        transactions: [MoneroTransaction]
    ) -> [ReceivingAddressOption] {
        let usedIndices = Set(transactions.compactMap { tx -> Int? in
            tx.type == .incoming ? tx.subaddressIndex : nil
        })

        var options = [ReceivingAddressOption(index: 0, name: SubaddressName.display(index: 0, label: ""))]
        var seen: Set<Int> = [0]
        let candidates = subaddresses
            .filter { $0.index > 0 && !$0.address.isEmpty }
            .sorted { $0.index < $1.index }
        for sub in candidates where !seen.contains(sub.index) {
            let inUse = !sub.label.isEmpty || sub.transactionsCount > 0 || usedIndices.contains(sub.index)
            guard inUse else { continue }
            seen.insert(sub.index)
            options.append(ReceivingAddressOption(
                index: sub.index,
                name: SubaddressName.display(index: sub.index, label: sub.label)
            ))
        }
        return options
    }

    /// "12 transactions", "3 received transactions on Main Address".
    static func summaryTitle(
        count: Int,
        type: TransactionListView.FilterType,
        receivingName: String?
    ) -> String {
        let noun = count == 1 ? "transaction" : "transactions"
        var title: String
        switch type {
        case .all: title = "\(count) \(noun)"
        case .incoming: title = "\(count) received \(noun)"
        case .outgoing: title = "\(count) sent \(noun)"
        case .pending: title = "\(count) pending \(noun)"
        }
        if let receivingName {
            title += " on \(receivingName)"
        }
        return title
    }
}


// MARK: - Transaction Row (Standard List Style)

struct TransactionRow: View {
    let transaction: MoneroTransaction
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(transaction.type == .incoming ? .green : .orange)
                .frame(width: 36, height: 36)
                .background(
                    (transaction.type == .incoming ? Color.green : Color.orange)
                        .opacity(0.15)
                )
                .cornerRadius(8)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.type == .incoming ? "Received" : "Sent")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Amount & Status
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(transaction.type == .incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(transaction.type == .incoming ? .green : .primary)

                // Status and fiat share one line under the amount, so the
                // row keeps its height whether or not the fiat value has
                // loaded yet.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if transaction.isStatusLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 6, height: 6)
                        } else {
                            Circle()
                                .fill(transaction.displayStatusColor)
                                .frame(width: 6, height: 6)
                            Text(transaction.displayStatusText)
                                .font(.caption2)
                                .foregroundColor(transaction.displayStatusColor)
                        }
                    }

                    if let fiatAtTime {
                        Text(fiatAtTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.type == .incoming ? "Received" : "Sent") \(XMRFormatter.format(transaction.amount)) XMR\(receivedOn.map { " on \($0)" } ?? "")\(fiatAtTime.map { ", worth \($0) at the time" } ?? ""), \(formattedDate), \(transaction.displayStatusText)")
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: transaction.timestamp)
    }

    /// The subaddress name an incoming transaction arrived on, spoken by
    /// VoiceOver only; the row stays as it was on screen.
    private var receivedOn: String? {
        walletManager.receivedOnRowName(for: transaction)
    }

    /// What the amount was worth when the transaction happened, in the
    /// selected currency. Nil until price history has loaded.
    private var fiatAtTime: String? {
        priceHistoryService.fiatValue(xmr: transaction.amount, at: transaction.timestamp)
            .map { priceService.formatFiat($0) }
    }
}

#Preview {
    let priceService = PriceService()
    let priceHistoryService = PriceHistoryService(priceService: priceService)
    NavigationStack {
        TransactionListView()
            .environmentObject(WalletManager())
            .environmentObject(priceService)
            .environmentObject(priceHistoryService)
    }
}
