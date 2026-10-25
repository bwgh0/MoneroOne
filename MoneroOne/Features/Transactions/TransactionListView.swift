import SwiftUI
import MoneroKit

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    @State private var searchText = ""
    @State private var filterType: FilterType = .all
    @ObservedObject private var paymentLinks = EnvelopeStore.shared
    /// Rows name contacts: a saved, renamed or deleted contact shows at once.
    @ObservedObject private var contactStore = ContactStore.shared
    /// Looks at sent links' envelopes while the Links filter is on screen.
    @StateObject private var linkChecker = PaymentLinksStatusChecker()
    @State private var isOnScreen = false
    /// Minor index of the receiving subaddress to show, nil for any.
    @State private var receivingIndex: Int?
    var asOf: Date? = nil
    var historyTransactions: [MoneroTransaction]? = nil
    /// The list column of the Activity split (regular width): a tap selects
    /// a row (`ActivityListItem.id`) and the detail column shows it. Nil on
    /// iPhone, where a row pushes its detail.
    var selection: Binding<String?>? = nil

    /// `initialFilter`: Links when the balance card's open-link lines open it.
    init(asOf: Date? = nil, historyTransactions: [MoneroTransaction]? = nil, initialFilter: FilterType = .all, selection: Binding<String?>? = nil) {
        self.asOf = asOf
        self.historyTransactions = historyTransactions
        self.selection = selection
        _filterType = State(initialValue: initialFilter)
    }

    private var sourceTransactions: [MoneroTransaction] {
        asOf == nil ? walletManager.mergedTransactions : (historyTransactions ?? walletManager.mergedTransactions)
    }

    enum FilterType: String, CaseIterable {
        case all = "All"
        case incoming = "Received"
        case outgoing = "Sent"
        case pending = "Pending"
        /// Payment link transactions: funding, reclaim and claim.
        case links = "Links"

        /// The menu and empty-state name, in the user's language.
        var title: String {
            switch self {
            case .all: return String(localized: "All", comment: "Transaction filter")
            case .incoming: return String(localized: "Received", comment: "Transaction filter")
            case .outgoing: return String(localized: "Sent", comment: "Transaction filter")
            case .pending: return String(localized: "Pending", comment: "Transaction filter")
            case .links: return String(localized: "Links", comment: "Transaction filter: payment link transactions")
            }
        }

        /// VoiceOver hint for the filter menu, a full sentence per filter.
        var showingHint: String {
            switch self {
            case .all: return String(localized: "Currently showing all transactions")
            case .incoming: return String(localized: "Currently showing received transactions")
            case .outgoing: return String(localized: "Currently showing sent transactions")
            case .pending: return String(localized: "Currently showing pending transactions")
            case .links: return String(localized: "Currently showing payment link transactions")
            }
        }

        /// Empty-state line when this filter leaves no rows.
        var emptyTitle: String {
            switch self {
            case .all: return String(localized: "No transactions yet")
            case .incoming: return String(localized: "No received transactions")
            case .outgoing: return String(localized: "No sent transactions")
            case .pending: return String(localized: "No pending transactions")
            case .links: return String(localized: "No payment links yet")
            }
        }

        /// Second empty-state line, for a filter that needs one.
        var emptyHint: String? {
            switch self {
            case .links: return String(localized: "In Send, choose Link to make one.", comment: "Activity, Links filter with no links")
            default: return nil
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
    private var linksToClaim: [EnvelopeRecord] {
        TransactionListLogic.linksToClaim(
            paymentLinks.records,
            type: filterType,
            receivingIndex: receivingIndex,
            search: searchText,
            asOf: asOf
        )
    }

    private var openSentWithoutRow: [EnvelopeRecord] {
        TransactionListLogic.openSentWithoutRow(
            paymentLinks.records,
            transactions: sourceTransactions,
            type: filterType,
            receivingIndex: receivingIndex,
            search: searchText,
            asOf: asOf,
            activeWalletId: walletManager.activeWallet?.id.uuidString,
            walletIds: walletManager.walletIds
        )
    }

    private var filteredTransactions: [MoneroTransaction] {
        // Search also finds a row by the name it shows ("To Savings").
        let namer = searchText.isEmpty ? nil : ActivityRowText.namer(walletManager)
        let linkRecords = paymentLinks.records
        return TransactionListLogic.filter(
            sourceTransactions,
            type: filterType,
            receivingIndex: receivingIndex,
            search: searchText,
            asOf: asOf,
            linkRecords: linkRecords,
            name: { tx in namer.flatMap { ActivityRowText.searchName(of: tx, namer: $0, linkRecords: linkRecords) } }
        )
    }

    private var receivingOptions: [ReceivingAddressOption] {
        TransactionListLogic.receivingAddressOptions(
            subaddresses: walletManager.subaddresses.map(SubaddressSummary.init),
            transactions: TransactionListLogic.through(asOf, transactions: sourceTransactions)
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
        let items = TransactionListLogic.items(transactions: filtered, linksToClaim: linksToClaim, openSent: openSentWithoutRow)
        let totals = TransactionListLogic.totals(of: filtered)
        // Fiat Mode leads with fiat totals priced like the rows below them.
        let fiatTotals = priceService.showFiatFirst
            ? TransactionListLogic.fiatTotals(of: filtered, priceAt: priceHistoryService.price(at:))
            : nil

        List {
            listRows(items, totals: totals, fiatTotals: fiatTotals)
        }
        .listStyle(.plain)
        // The split's list column would draw on the sidebar's gray material,
        // which muddies the selected row's tint; the page background, as on
        // iPhone.
        .scrollContentBackground(selection == nil ? .automatic : .hidden)
        .background(selection == nil ? Color.clear : Color(.systemBackground))
        .animation(.easeInOut(duration: 0.25), value: items.isEmpty)
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
        .onAppear {
            isOnScreen = true
            tidyPaymentLinks()
            checkLinksIfShown()
            // The split opens on the newest row, as Mail opens on the
            // newest message, unless a dashboard row chose one.
            if let selection, selection.wrappedValue == nil {
                selection.wrappedValue = shownOrder(items).first(where: \.opensDetail)?.id
            }
        }
        .onDisappear {
            isOnScreen = false
            linkChecker.stop()
        }
        .onChange(of: filterType) { _, type in
            if type == .links { checkLinksIfShown() } else { linkChecker.stop() }
        }
        // The active wallet publishes each new block, so a pending link can
        // reach the unlock depth while the Links filter is open.
        .onChange(of: unlockedPendingLinkCounts) { _, counts in
            guard !counts.isEmpty else { return }
            checkLinksIfShown()
        }
    }

    /// The rows top to bottom: under Links, the open links come first.
    private func shownOrder(_ items: [ActivityListItem]) -> [ActivityListItem] {
        guard filterType == .links else { return items }
        let sections = TransactionListLogic.linkSections(items, records: paymentLinks.records)
        return sections.open + sections.history
    }

    @ViewBuilder
    private func listRows(_ items: [ActivityListItem], totals: TransactionTotals, fiatTotals: FiatTotals?) -> some View {
        if let asOf {
            ActivityAsOfText(asOf: asOf)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if items.isEmpty {
            emptyState
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if filterType == .links {
            // The card first, then the links that still hold money, then
            // the rest.
            let sections = TransactionListLogic.linkSections(items, records: paymentLinks.records)
            summaryCard(
                totals,
                fiatTotals: fiatTotals,
                title: TransactionListLogic.linksSummaryTitle(items, openCount: sections.open.count, records: paymentLinks.records)
            )
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if !sections.open.isEmpty {
                sectionHeader(String(localized: "Open", comment: "Activity, Links filter: links that still hold money"))
                rows(sections.open)
            }
            if !sections.history.isEmpty {
                sectionHeader(String(localized: "History", comment: "Activity, Links filter: links that are done"))
                rows(sections.history)
            }
        } else {
            summaryCard(totals, fiatTotals: fiatTotals)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            rows(items)
        }
    }

    // MARK: - Payment link checks

    /// Housekeeping that needs no envelope: adopt a funding transaction a
    /// sent record missed, and forget a received link's words once our
    /// claim is mined.
    private func tidyPaymentLinks() {
        guard asOf == nil else { return }
        PaymentLinksStatusChecker.reconcileFunding(store: paymentLinks, walletManager: walletManager)
    }

    /// Under Links (now only), look at sent links someone could have
    /// claimed, so their rows say so. A look stops the active wallet for
    /// a moment, so no other filter runs it.
    private func checkLinksIfShown() {
        guard isOnScreen, asOf == nil, filterType == .links else { return }
        paymentLinks.reload()
        tidyPaymentLinks()
        linkChecker.start(walletManager: walletManager, store: paymentLinks)
    }

    /// Live counts of the pending sent links at the unlock depth or more.
    private var unlockedPendingLinkCounts: [Int] {
        guard filterType == .links else { return [] }
        return paymentLinks.sent.compactMap { record in
            guard record.status == .pending,
                  let count = PaymentLinkDisplay(record: record, walletManager: walletManager).confirmations,
                  count >= EnvelopeLink.confirmationsToUnlock else { return nil }
            return count
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
                .foregroundColor(isFilterActive ? .brand : .primary)
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

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ items: [ActivityListItem]) -> some View {
        ForEach(items.map(ActivityListRow.init)) { row in
            if let selection, row.item.opensDetail {
                selectableRow(row.item, isSelected: selection.wrappedValue == row.id)
            } else {
                pushRow(row.item)
            }
        }
    }

    /// A row of the split's list column: the detail column shows it, so the
    /// row carries no chevron. The selected row gets the brand tint. A plain
    /// button, not List selection: the list's selection style turned the
    /// row title white on the tint and drew a square focus ring.
    private func selectableRow(_ item: ActivityListItem, isSelected: Bool) -> some View {
        Button {
            selection?.wrappedValue = item.id
        } label: {
            Group {
                switch item {
                case .transaction(let transaction):
                    TransactionRow(transaction: transaction)
                case .openSent(let record):
                    PaymentLinkOpenSentRow(record: record)
                case .linkToClaim(let record):
                    PaymentLinkToClaimRow(record: record)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.brand.opacity(0.15) : Color.clear)
                .padding(.horizontal, 8)
        )
    }

    @ViewBuilder
    private func pushRow(_ item: ActivityListItem) -> some View {
        switch item {
        case .transaction(let transaction):
            NavigationLink {
                ActivityDetailView(transaction: transaction)
            } label: {
                TransactionRow(transaction: transaction)
            }
        case .linkToClaim(let record):
            PaymentLinkToClaimRow(record: record)
        case .openSent(let record):
            NavigationLink {
                PaymentLinkDetailView(recordId: record.id, role: .sent)
            } label: {
                PaymentLinkOpenSentRow(record: record)
            }
        }
    }

    /// "Open", "History": a heading row, as Wallet's Recent Activity.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Summary card

    /// Totals for the rows on screen. Review-card style (radius 16,
    /// `secondarySystemBackground`) like the send review, since it is a
    /// table of amounts, not a hero. `fiatTotals` (Fiat Mode, every row
    /// priced) puts fiat on top of each column.
    private func summaryCard(_ totals: TransactionTotals, fiatTotals: FiatTotals?, title: String? = nil) -> some View {
        let title = title ?? TransactionListLogic.summaryTitle(
            count: totals.count,
            type: filterType,
            receivingName: receivingFilterName
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
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
        .accessibilityLabel(summaryAccessibilityLabel(totals, fiatTotals: fiatTotals, title: title))
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

    private func summaryAccessibilityLabel(_ totals: TransactionTotals, fiatTotals: FiatTotals?, title: String) -> String {
        var parts = [title]
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
                Image(systemName: filterType == .links ? "link" : "line.3.horizontal.decrease.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(filterType.emptyTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let hint = filterType.emptyHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
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
    /// Inclusive cutoff shared by recent activity and See All. Filtering
    /// changes which records are visible; their full details stay intact.
    static func through(_ date: Date?, transactions: [MoneroTransaction]) -> [MoneroTransaction] {
        guard let date else { return transactions }
        return transactions.filter { $0.timestamp <= date }
    }

    /// Type filter, receiving-address filter and search compose with AND.
    /// A receiving-address filter keeps incoming transactions only:
    /// sends spend from the account, not from one subaddress. Links keeps
    /// the transactions of a payment link in `linkRecords`.
    static func matches(
        _ tx: MoneroTransaction,
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String,
        linkRecords: [EnvelopeRecord] = [],
        name: String? = nil
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
        case .links:
            guard PaymentLinkActivity.match(transactionId: tx.id, isIncoming: tx.type == .incoming, records: linkRecords) != nil else { return false }
        }

        if let receivingIndex {
            guard tx.type == .incoming, tx.subaddressIndex == receivingIndex else { return false }
        }

        if !search.isEmpty {
            let hit = tx.id.localizedCaseInsensitiveContains(search)
                || tx.address.localizedCaseInsensitiveContains(search)
                || (tx.memo?.localizedCaseInsensitiveContains(search) ?? false)
                || (name?.localizedCaseInsensitiveContains(search) ?? false)
            guard hit else { return false }
        }

        return true
    }

    static func filter(
        _ transactions: [MoneroTransaction],
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String,
        asOf: Date? = nil,
        linkRecords: [EnvelopeRecord] = [],
        name: (MoneroTransaction) -> String? = { _ in nil }
    ) -> [MoneroTransaction] {
        let rows = through(asOf, transactions: transactions).filter {
            matches($0, type: type, receivingIndex: receivingIndex, search: search, linkRecords: linkRecords,
                    name: search.isEmpty ? nil : name($0))
        }
        return type == .links ? oneFundingRowPerLink(rows, records: linkRecords) : rows
    }

    /// A funding wallet2 split into several transactions: the Links filter
    /// shows one row for the link, its funding txid's when shown. All
    /// keeps every transaction.
    static func oneFundingRowPerLink(_ rows: [MoneroTransaction], records: [EnvelopeRecord]) -> [MoneroTransaction] {
        func funding(_ tx: MoneroTransaction) -> EnvelopeRecord? {
            guard tx.type == .outgoing,
                  let link = PaymentLinkActivity.match(transactionId: tx.id, isIncoming: false, records: records),
                  link.kind == .funding else { return nil }
            return link.record
        }
        var kept: [String: String] = [:]
        for tx in rows {
            guard let record = funding(tx) else { continue }
            let key = EnvelopeStore.account(for: record)
            if kept[key] == nil || tx.id == record.fundingTxid { kept[key] = tx.id }
        }
        return rows.filter { tx in
            guard let record = funding(tx) else { return true }
            return kept[EnvelopeStore.account(for: record)] == tx.id
        }
    }

    /// Under All and Links, the links sent to us that wait to be claimed,
    /// newest first: their claim is no transaction yet, so each gets a row
    /// of its own among the transactions, at the date it was opened. Now
    /// only, with no search or address filter. Our open links are not here:
    /// their funding rows say where each one stands, so every link shows
    /// once. Links also lists the ones whose money never came in their
    /// days to claim, under History as Expired; All leaves them out.
    static func linksToClaim(
        _ records: [EnvelopeRecord],
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String,
        asOf: Date?,
        now: Date = Date()
    ) -> [EnvelopeRecord] {
        guard type == .all || type == .links, asOf == nil, search.isEmpty, receivingIndex == nil else { return [] }
        return records
            .filter { type == .links ? OpenPaymentLinks.isToClaim($0) : OpenPaymentLinks.isWaitingToClaim($0, now: now) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Under Links, our open links whose funding has no row in this
    /// wallet's history (its funding wallet left this device, or another
    /// wallet funded it), newest first: each gets a row of its own in Open,
    /// at the date it was made, so Share and Reclaim stay in reach. Now
    /// only, with no search or address filter.
    static func openSentWithoutRow(
        _ records: [EnvelopeRecord],
        transactions: [MoneroTransaction],
        type: TransactionListView.FilterType,
        receivingIndex: Int?,
        search: String,
        asOf: Date?,
        activeWalletId: String?,
        walletIds: Set<String>?
    ) -> [EnvelopeRecord] {
        guard type == .links, asOf == nil, search.isEmpty, receivingIndex == nil else { return [] }
        let rows = Set(transactions.filter { $0.type == .outgoing }.map(\.id))
        return records
            .filter { record in
                guard OpenPaymentLinks.isOpenSent(record, activeWalletId: activeWalletId, walletIds: walletIds),
                      record.knownFundingTxid != nil else { return false }
                return !record.ownFundingTxids.contains(where: rows.contains)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The transactions, the links to claim and our open links with no
    /// funding row in one list, newest first.
    static func items(transactions: [MoneroTransaction], linksToClaim: [EnvelopeRecord], openSent: [EnvelopeRecord] = []) -> [ActivityListItem] {
        guard !linksToClaim.isEmpty || !openSent.isEmpty else { return transactions.map(ActivityListItem.transaction) }
        let all = transactions.map(ActivityListItem.transaction) + linksToClaim.map(ActivityListItem.linkToClaim)
            + openSent.map(ActivityListItem.openSent)
        // Stable: transactions keep their order among equal dates.
        return all.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The Links filter's two groups. Open: the links that still hold
    /// money (our funding rows that are Waiting, Ready or Expired, and the
    /// links sent to us not claimed yet). History: every other link row,
    /// a link sent to us whose money never came in its days to claim among
    /// them. Each newest first; every row once.
    static func linkSections(_ items: [ActivityListItem], records: [EnvelopeRecord], now: Date = Date()) -> (open: [ActivityListItem], history: [ActivityListItem]) {
        var open: [ActivityListItem] = []
        var history: [ActivityListItem] = []
        for item in items {
            switch item {
            case .linkToClaim(let record):
                if OpenPaymentLinks.isWaitingToClaim(record, now: now) {
                    open.append(item)
                } else {
                    history.append(item)
                }
            case .openSent:
                open.append(item)
            case .transaction(let tx):
                let link = PaymentLinkActivity.match(transactionId: tx.id, isIncoming: tx.type == .incoming, records: records)
                if let link, link.kind == .funding, !link.record.status.isSettled, tx.status != .failed {
                    open.append(item)
                } else {
                    history.append(item)
                }
            }
        }
        return (open, history)
    }

    /// The Links filter's card: "7 links · 4 open", counting each link once
    /// (a reclaimed link has a funding row and a reclaim row).
    static func linksSummaryTitle(_ items: [ActivityListItem], openCount: Int, records: [EnvelopeRecord]) -> String {
        var links = Set<String>()
        for item in items {
            switch item {
            case .linkToClaim(let record), .openSent(let record):
                links.insert(EnvelopeStore.account(for: record))
            case .transaction(let tx):
                if let link = PaymentLinkActivity.match(transactionId: tx.id, isIncoming: tx.type == .incoming, records: records) {
                    links.insert(EnvelopeStore.account(for: link.record))
                }
            }
        }
        let count = String(localized: "\(links.count) links", comment: "Activity, Links filter card: how many payment links")
        guard openCount > 0 else { return count }
        return String(localized: "\(count) · \(openCount) open", comment: "Activity, Links filter card: how many links, then how many still hold money")
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
        case .links: title = String(localized: "\(count) link transactions", comment: "Activity summary under the Links filter: payment link transactions")
        }
        if let receivingName {
            title = String(localized: "\(title) on \(receivingName)", comment: "Transaction count, then the receiving address name")
        }
        return title
    }
}


// MARK: - List items

/// One Activity row: a transaction, or a link sent to us that waits to be
/// claimed (no transaction yet).
/// A list item with the state its row shows. `ActivityListItem`'s `==`
/// uses `MoneroTransaction`'s, which compares ids only, so a list of items
/// alone looked unchanged after a new block.
struct ActivityListRow: Identifiable, Equatable {
    let item: ActivityListItem
    let state: TransactionRowState?

    init(_ item: ActivityListItem) {
        self.item = item
        if case .transaction(let transaction) = item {
            state = transaction.rowState
        } else {
            state = nil
        }
    }

    var id: String { item.id }
}

enum ActivityListItem: Identifiable, Equatable {
    case transaction(MoneroTransaction)
    case linkToClaim(EnvelopeRecord)
    /// One of our open links whose funding has no row here.
    case openSent(EnvelopeRecord)

    var id: String {
        switch self {
        case .transaction(let tx): return "tx.\(tx.id).\(tx.type == .incoming ? "in" : "out")"
        case .linkToClaim(let record): return "link.\(record.id)"
        case .openSent(let record): return "sent.\(record.id)"
        }
    }

    /// A tap opens a detail page: a transaction, or one of our open links.
    /// A link to claim opens its claim sheet instead.
    var opensDetail: Bool {
        if case .linkToClaim = self { return false }
        return true
    }

    /// Where the row sits: the transaction's date, or when the link was
    /// opened here.
    var date: Date {
        switch self {
        case .transaction(let tx): return tx.timestamp
        case .linkToClaim(let record), .openSent(let record): return record.createdAt
        }
    }
}

// MARK: - Transaction Row (Standard List Style)

struct TransactionRow: View {
    let transaction: MoneroTransaction
    /// Draws the row again at each new confirmation (see `TransactionRowState`).
    private let state: TransactionRowState
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    /// Payment link transactions show the link's name, amount and state.
    @ObservedObject private var paymentLinks = EnvelopeStore.shared
    /// Rows name contacts: a saved, renamed or deleted contact shows at once.
    @ObservedObject private var contactStore = ContactStore.shared

    init(transaction: MoneroTransaction) {
        self.transaction = transaction
        self.state = transaction.rowState
    }

    var body: some View {
        let row = ActivityRowText(transaction: transaction, date: formattedDate, walletManager: walletManager, store: paymentLinks)
        let amount = amount(row.xmr)
        ActivityRowLayout(
            systemImage: row.systemImage,
            isIncoming: transaction.type == .incoming,
            showsLinkBadge: row.showsLinkBadge,
            badgeSymbol: row.badgeSymbol ?? "link",
            ringState: ConfirmationRing.state(of: transaction),
            title: row.title,
            subtitle: row.subtitle
        ) { alignment in
            TransactionAmountColumn(transaction: transaction, amount: amount, linkStatus: row.linkStatus, alignment: alignment)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel(amount: amount))
    }

    private func amount(_ xmr: Decimal) -> TransactionAmountText {
        TransactionAmountText(
            isIncoming: transaction.type == .incoming,
            xmr: xmr,
            fiatAtTime: fiatAtTime(xmr),
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
    private func fiatAtTime(_ xmr: Decimal) -> String? {
        priceHistoryService.fiatValue(xmr: xmr, at: transaction.timestamp)
            .map { priceService.formatFiat($0) }
    }
}

// MARK: - Row layout (shared by Activity's rows)

/// One Activity row: the direction's glyph in its tinted tile, the title
/// with the date under it, and the amount column at the end. A transaction
/// and a payment link waiting to be claimed both use it, so they read
/// alike.
struct ActivityRowLayout<Amount: View>: View {
    let systemImage: String
    let isIncoming: Bool
    /// A payment link's row: the disc gets the link badge.
    var showsLinkBadge = false
    /// The badge's glyph: the link, or the wallet on a send between your
    /// wallets.
    var badgeSymbol = "link"
    /// A transaction's confirmation ring on the disc.
    var ringState: ConfirmationRing.State = .hidden
    /// "Received", "Sent", or a payment link's name.
    let title: String
    let subtitle: String
    /// The amount column, aligned for where it sits.
    @ViewBuilder let amount: (HorizontalAlignment) -> Amount
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            // At accessibility sizes the amount goes under the title: side
            // by side, a whole "Reclaimed by Link" pushed the row off screen.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        icon
                        details(stacked: true)
                    }
                    // Under the title text: 40 disc + 12.
                    amount(.leading)
                        .padding(.leading, TransactionDisc.size + 12)
                }
            } else {
                HStack(spacing: 12) {
                    icon
                    details(stacked: false)

                    Spacer()

                    // Amount & Status
                    amount(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color { isIncoming ? .green : .brand }

    /// The 40 pt disc that Home's rows use.
    private var icon: some View {
        TransactionDisc(systemImage: systemImage, tint: tint, ringState: ringState)
            .paymentLinkBadge(tint, isShown: showsLinkBadge, symbol: badgeSymbol)
    }

    private func details(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                // The label color inside a Button too, which would tint it.
                .foregroundStyle(.primary)
                // Whole: next to a long amount, "Получено" broke with a
                // hyphen; the amount column gives way instead. A link's
                // name can be long: it ends in "…" before the amount does.
                // Stacked, the title has the row's width and wraps if it must.
                .fixedSize(horizontal: !stacked && !showsLinkBadge, vertical: true)
                .lineLimit(stacked ? nil : 1)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                // The date on one line at the usual sizes: next to a link's
                // "Ready to claim" it broke after "at". The amount column
                // puts its status over the value instead.
                .fixedSize(horizontal: !stacked && dynamicTypeSize <= .large, vertical: false)
        }
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

    private init(primary: String, secondary: String?, isFiatFirst: Bool, spoken: String) {
        self.primary = primary
        self.secondary = secondary
        self.isFiatFirst = isFiatFirst
        self.spoken = spoken
    }

    /// Money coming in that is not ours yet, an estimate (a payment link's
    /// claim, less a fee not known exactly): "+~0.0154" over "~$2.47", or
    /// "+~$2.47" over "~0.0154 XMR" in Fiat Mode. `fiatNow` is its value
    /// at today's price; nil with no price.
    static func incomingEstimate(xmr: Decimal, fiatNow: String?, fiatFirst: Bool) -> TransactionAmountText {
        let xmrText = XMRFormatter.format(xmr)
        if fiatFirst, let fiatNow {
            let compact = XMRFormatter.formatCompact(xmr)
            return TransactionAmountText(
                primary: "+~" + fiatNow,
                secondary: "~\(compact) XMR",
                isFiatFirst: true,
                spoken: String(localized: "about \(fiatNow), about \(compact) XMR", comment: "VoiceOver: Fiat Mode, an estimated amount not received yet: fiat at today's price, then XMR")
            )
        }
        return TransactionAmountText(
            primary: "+~" + xmrText,
            secondary: fiatNow.map { "~" + $0 },
            isFiatFirst: false,
            spoken: String(localized: "about \(xmrText) XMR", comment: "VoiceOver: an estimated amount not received yet")
                + (fiatNow.map { String(localized: ", worth about \($0)", comment: "VoiceOver: fiat value at today's price of an amount not received yet") } ?? "")
        )
    }
}

/// The trailing column of a transaction row: the amount on top, then the
/// status and the other currency on one line where they fit, so the row
/// keeps its height whether or not the fiat value has loaded yet. In Fiat
/// Mode the XMR amount is too long to share that line with the status, so
/// it gets a line of its own under it.
struct TransactionAmountColumn: View {
    let amount: TransactionAmountText
    let isIncoming: Bool
    /// The transaction whose status shows under the amount.
    let transaction: MoneroTransaction?
    /// Draws the status again at each new confirmation (see `TransactionRowState`).
    private let state: TransactionRowState?
    /// A payment link's state, shown in place of the transaction's status.
    let linkStatus: PaymentLinkRowStatus?
    /// Leading when the column sits under the title (accessibility sizes).
    var alignment: HorizontalAlignment = .trailing

    init(
        transaction: MoneroTransaction,
        amount: TransactionAmountText,
        linkStatus: PaymentLinkRowStatus? = nil,
        alignment: HorizontalAlignment = .trailing
    ) {
        self.amount = amount
        self.isIncoming = transaction.type == .incoming
        self.transaction = transaction
        self.state = transaction.rowState
        self.linkStatus = linkStatus
        self.alignment = alignment
    }

    /// No transaction yet (a link sent to us, not claimed): the link's
    /// state under the amount.
    init(amount: TransactionAmountText, isIncoming: Bool, linkStatus: PaymentLinkRowStatus, alignment: HorizontalAlignment = .trailing) {
        self.amount = amount
        self.isIncoming = isIncoming
        self.transaction = nil
        self.state = nil
        self.linkStatus = linkStatus
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(amount.primary)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isIncoming ? .green : .primary)
                // One line: a 12-decimal amount in the narrow iPad panel
                // wrapped its last digit onto a line of its own.
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if amount.isFiatFirst {
                VStack(alignment: alignment, spacing: 2) {
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
                    VStack(alignment: alignment, spacing: 2) {
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

    /// The status word cross-fades when it changes (crossFade 0.35 s):
    /// "Pending" to "Locked" at the first block, to "Confirmed" at 10.
    private var status: some View {
        statusLabel
            .animation(.easeInOut(duration: 0.35), value: statusText)
    }

    private var statusText: String {
        linkStatus?.text ?? transaction?.displayStatusText ?? ""
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let linkStatus {
            PaymentLinkStatusLabel(status: linkStatus)
        } else if let transaction {
            status(of: transaction)
        }
    }

    private func status(of transaction: MoneroTransaction) -> some View {
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
                    .contentTransition(.opacity)
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
