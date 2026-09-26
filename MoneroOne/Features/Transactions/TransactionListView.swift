import SwiftUI
import MoneroKit

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    @State private var searchText = ""
    @State private var filterType: FilterType = .all
    /// Minor index of the receiving subaddress to show, nil for any.
    @State private var receivingIndex: Int?

    enum FilterType: String, CaseIterable {
        case all = "All"
        case incoming = "Received"
        case outgoing = "Sent"
        case pending = "Pending"

        /// The menu and empty-state name, in the user's language.
        var title: String {
            switch self {
            case .all: return String(localized: "All", comment: "Transaction filter")
            case .incoming: return String(localized: "Received", comment: "Transaction filter")
            case .outgoing: return String(localized: "Sent", comment: "Transaction filter")
            case .pending: return String(localized: "Pending", comment: "Transaction filter")
            }
        }

        /// VoiceOver hint for the filter menu, a full sentence per filter.
        var showingHint: String {
            switch self {
            case .all: return String(localized: "Currently showing all transactions")
            case .incoming: return String(localized: "Currently showing received transactions")
            case .outgoing: return String(localized: "Currently showing sent transactions")
            case .pending: return String(localized: "Currently showing pending transactions")
            }
        }

        /// Empty-state line when this filter leaves no rows.
        var emptyTitle: String {
            switch self {
            case .all: return String(localized: "No transactions yet")
            case .incoming: return String(localized: "No received transactions")
            case .outgoing: return String(localized: "No sent transactions")
            case .pending: return String(localized: "No pending transactions")
            }
        }
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
        // Fiat Mode leads with fiat totals priced like the rows below them.
        let fiatTotals = priceService.showFiatFirst
            ? TransactionListLogic.fiatTotals(of: filtered, priceAt: priceHistoryService.price(at:))
            : nil

        List {
            if filtered.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                summaryCard(totals, fiatTotals: fiatTotals)
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
                        Text(type.title)
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
                    Text(receivingFilterName ?? String(localized: "Any"))
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
        var hint = filterType.showingHint
        if let receivingFilterName {
            hint += String(localized: " on \(receivingFilterName)", comment: "VoiceOver: receiving subaddress name after the amount")
        }
        return hint
    }

    // MARK: - Summary card

    /// Totals for the rows on screen. Review-card style (radius 16,
    /// `secondarySystemBackground`) like the send review, since it is a
    /// table of amounts, not a hero. `fiatTotals` (Fiat Mode, every row
    /// priced) puts fiat on top of each column.
    private func summaryCard(_ totals: TransactionTotals, fiatTotals: FiatTotals?) -> some View {
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
                    title: String(localized: "Received"),
                    sign: "+",
                    amount: totals.received,
                    fiatAtTime: fiatTotals?.received,
                    tint: .green
                )

                // Sends spend from the whole account, so a per-address
                // total would be meaningless; hide it under that filter.
                if receivingIndex == nil {
                    totalColumn(
                        title: String(localized: "Sent"),
                        sign: "-",
                        amount: totals.sent,
                        fiatAtTime: fiatTotals?.sent,
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
        .accessibilityLabel(summaryAccessibilityLabel(totals, fiatTotals: fiatTotals))
    }

    /// One column of the summary card. XMR on top with today's fiat value
    /// under it; with `fiatAtTime` (Fiat Mode) the fiat total moves to the
    /// top and the XMR total under it.
    private func totalColumn(title: String, sign: String, amount: Decimal, fiatAtTime: Decimal?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fiatAtTime {
                Text("\(sign)\(priceService.formatFiat(fiatAtTime))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(XMRFormatter.format(amount)) XMR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("\(sign)\(XMRFormatter.format(amount)) XMR")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // One line: a 12-decimal total pushed "XMR" onto a
                    // line of its own in the half-width column.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let fiat = priceService.formatFiatValue(amount) {
                    Text("≈ \(fiat)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryAccessibilityLabel(_ totals: TransactionTotals, fiatTotals: FiatTotals?) -> String {
        var parts = [TransactionListLogic.summaryTitle(
            count: totals.count,
            type: filterType,
            receivingName: receivingFilterName
        )]
        if let fiatTotals {
            parts.append(String(localized: "received \(priceService.formatFiat(fiatTotals.received)) at the time, \(XMRFormatter.format(totals.received)) XMR", comment: "VoiceOver: Fiat Mode total received in the list, fiat at each transaction's date, then XMR"))
            if receivingIndex == nil {
                parts.append(String(localized: "sent \(priceService.formatFiat(fiatTotals.sent)) at the time, \(XMRFormatter.format(totals.sent)) XMR including fees", comment: "VoiceOver: Fiat Mode total sent in the list, fiat at each transaction's date, then XMR"))
            }
            return parts.joined(separator: ", ")
        }
        var received = String(localized: "received \(XMRFormatter.format(totals.received)) XMR", comment: "VoiceOver: total received in the list")
        if let fiat = priceService.formatFiatValue(totals.received) {
            received += String(localized: ", about \(fiat)", comment: "VoiceOver: approximate fiat value after an amount")
        }
        parts.append(received)
        if receivingIndex == nil {
            var sent = String(localized: "sent \(XMRFormatter.format(totals.sent)) XMR including fees", comment: "VoiceOver: total sent in the list")
            if let fiat = priceService.formatFiatValue(totals.sent) {
                sent += String(localized: ", about \(fiat)", comment: "VoiceOver: approximate fiat value after an amount")
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
                Text(filterType.emptyTitle)
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

/// Received and sent totals in fiat, each transaction priced on its own
/// date, so they add up to what the rows show in Fiat Mode.
struct FiatTotals: Equatable {
    let received: Decimal
    /// Amount plus fee of every outgoing transaction.
    let sent: Decimal
}

enum SubaddressName {
    /// The name the receive picker gives a subaddress: "Main Address"
    /// for index 0, else the user's label with its emoji kept in front,
    /// else "Subaddress #n".
    static func display(index: Int, label: String) -> String {
        if index == 0 { return String(localized: "Main Address") }
        let parts = splitSubaddressLabel(label)
        let name = parts.name.isEmpty ? String(localized: "Subaddress #\(index)") : parts.name
        return joinSubaddressLabel(emoji: parts.emoji, name: name)
    }

    /// The name of `index` in the wallet's list: its label, else
    /// "Subaddress #index". Never its position in the list, which drifts
    /// from the index when the list has a gap or has not listed a new
    /// address yet.
    static func display(index: Int, in subaddresses: [SubaddressSummary]) -> String {
        display(index: index, label: subaddresses.first { $0.index == index }?.label ?? "")
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

    /// `totals(of:)` in fiat, each transaction at `priceAt` its own date.
    /// Nil when a counted transaction has no price yet: a sum with gaps
    /// would read as a real total.
    static func fiatTotals(
        of transactions: [MoneroTransaction],
        priceAt: (Date) -> Double?
    ) -> FiatTotals? {
        var received: Decimal = 0
        var sent: Decimal = 0
        for tx in transactions where tx.status != .failed {
            guard let price = priceAt(tx.timestamp) else { return nil }
            switch tx.type {
            case .incoming:
                received += tx.amount * Decimal(price)
            case .outgoing:
                sent += (tx.amount + tx.fee) * Decimal(price)
            }
        }
        return FiatTotals(received: received, sent: sent)
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
        // Plural forms live in the string catalog ("1 transaction").
        var title: String
        switch type {
        case .all: title = String(localized: "\(count) transactions")
        case .incoming: title = String(localized: "\(count) received transactions")
        case .outgoing: title = String(localized: "\(count) sent transactions")
        case .pending: title = String(localized: "\(count) pending transactions")
        }
        if let receivingName {
            title = String(localized: "\(title) on \(receivingName)", comment: "Transaction count, then the receiving address name")
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
                    // Whole: next to a long amount, "Получено" broke with a
                    // hyphen; the amount column gives way instead.
                    .fixedSize()

                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Amount & Status
            TransactionAmountColumn(transaction: transaction, amount: amount)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.type == .incoming ? String(localized: "Received") : String(localized: "Sent")) \(amount.spoken), \(formattedDate), \(transaction.displayStatusText)")
    }

    private var amount: TransactionAmountText {
        TransactionAmountText(
            transaction: transaction,
            fiatAtTime: fiatAtTime,
            fiatFirst: priceService.showFiatFirst,
            receivedOn: receivedOn
        )
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

// MARK: - Transaction amount (shared by every transaction row)

/// The amount lines of a transaction row: XMR on top and its fiat value
/// at the time under it, or the other way round in Fiat Mode. A row whose
/// price has not loaded keeps XMR on top in both modes.
struct TransactionAmountText: Equatable {
    /// "+1.2345", or "+$150.23" in Fiat Mode.
    let primary: String
    /// "$150.23", or "1.2345 XMR" in Fiat Mode, where it is the short
    /// form (the detail sheet shows every digit). Nil with no price.
    let secondary: String?
    /// True when fiat leads (Fiat Mode with a price loaded).
    let isFiatFirst: Bool
    /// The amount as VoiceOver reads it, in the order the row shows it:
    /// "1.2345 XMR on Savings, worth $150.23 at the time", or
    /// "$150.23 at the time, 1.2345 XMR on Savings".
    let spoken: String

    init(isIncoming: Bool, xmr: Decimal, fiatAtTime: String?, fiatFirst: Bool, receivedOn: String? = nil) {
        let sign = isIncoming ? "+" : "-"
        let xmrText = XMRFormatter.format(xmr)
        let on = receivedOn.map { String(localized: " on \($0)", comment: "VoiceOver: receiving subaddress name after the amount") } ?? ""
        if fiatFirst, let fiatAtTime {
            let compact = XMRFormatter.formatCompact(xmr)
            isFiatFirst = true
            primary = sign + fiatAtTime
            secondary = "\(compact) XMR"
            spoken = String(localized: "\(fiatAtTime) at the time, \(compact) XMR", comment: "VoiceOver: Fiat Mode row amount, the fiat value when the transaction happened, then XMR") + on
        } else {
            isFiatFirst = false
            primary = sign + xmrText
            secondary = fiatAtTime
            spoken = "\(xmrText) XMR" + on + (fiatAtTime.map { String(localized: ", worth \($0) at the time", comment: "VoiceOver: fiat value when the transaction happened") } ?? "")
        }
    }

    init(transaction: MoneroTransaction, fiatAtTime: String?, fiatFirst: Bool, receivedOn: String?) {
        self.init(
            isIncoming: transaction.type == .incoming,
            xmr: transaction.amount,
            fiatAtTime: fiatAtTime,
            fiatFirst: fiatFirst,
            receivedOn: receivedOn
        )
    }
}

/// The trailing column of a transaction row: the amount on top, then the
/// status and the other currency on one line where they fit, so the row
/// keeps its height whether or not the fiat value has loaded yet. In Fiat
/// Mode the XMR amount is too long to share that line with the status, so
/// it gets a line of its own under it.
struct TransactionAmountColumn: View {
    let transaction: MoneroTransaction
    let amount: TransactionAmountText

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(amount.primary)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(transaction.type == .incoming ? .green : .primary)
                // One line: a 12-decimal amount in the narrow iPad panel
                // wrapped its last digit onto a line of its own.
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if amount.isFiatFirst {
                VStack(alignment: .trailing, spacing: 2) {
                    status
                    secondary
                }
            } else {
                // One line when both fit whole; else the value goes under
                // the status. Squeezed on one line, "Подтверждена" broke
                // with a hyphen or the value shrank to "…".
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        status
                        secondary
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        status
                        secondary
                    }
                }
            }
        }
        // Sized before the row's spacer, which otherwise took an even
        // share and cut a 12-decimal amount to "…".
        .layoutPriority(1)
    }

    private var status: some View {
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
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if let secondary = amount.secondary {
            Text(secondary)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
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
