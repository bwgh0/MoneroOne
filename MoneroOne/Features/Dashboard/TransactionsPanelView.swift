import SwiftUI

/// Full-height scrollable transaction panel for iPad Command Center
struct TransactionsPanelView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var selectedTransaction: MoneroTransaction?
    var onSeeAll: (() -> Void)?
    /// Shows the "As of" line for as long as History is open.
    var isHistoryOpen = false
    var asOf: Date? = nil
    var historyTransactions: [MoneroTransaction]? = nil

    private var activity: [MoneroTransaction] {
        let source = asOf == nil ? walletManager.mergedTransactions : (historyTransactions ?? walletManager.mergedTransactions)
        return TransactionListLogic.through(asOf, transactions: source)
    }

    private var isSyncing: Bool {
        switch walletManager.syncState {
        case .syncing, .connecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        // Filtered once per render; a scrub renders on every step.
        let activity = self.activity
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Activity")
                        .font(.headline)
                    if isHistoryOpen {
                        ActivityAsOfText(asOf: asOf)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if !activity.isEmpty {
                    Button {
                        onSeeAll?()
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(.brand)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Transaction list
            if activity.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(activity) { transaction in
                            TransactionPanelRow(transaction: transaction) {
                                selectedTransaction = transaction
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $selectedTransaction) { transaction in
            NavigationStack {
                ActivityDetailView(transaction: transaction)
            }
            .closesForPaymentLink()
            .presentationDetents([.fraction(0.75), .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if asOf != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No transactions by this time")
                    .font(.subheadline.weight(.medium))
                Text("Move forward in history or return to Now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isSyncing {
                ProgressView()
                    .tint(.brand)
                Text("Syncing transactions...")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("Your transactions will appear here once synced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No transactions yet")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        }
        .padding()
    }
}

/// Transaction row for the panel (similar to RecentTransactionCard but adapted for panel)
struct TransactionPanelRow: View {
    let transaction: MoneroTransaction
    let onTap: () -> Void
    /// Draws the row again at each new confirmation (see `TransactionRowState`).
    private let state: TransactionRowState
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    /// Payment link transactions show the link's name, amount and state.
    @ObservedObject private var paymentLinks = EnvelopeStore.shared
    /// Rows name contacts: a saved, renamed or deleted contact shows at once.
    @ObservedObject private var contactStore = ContactStore.shared

    init(transaction: MoneroTransaction, onTap: @escaping () -> Void) {
        self.transaction = transaction
        self.onTap = onTap
        self.state = transaction.rowState
    }

    var body: some View {
        let row = ActivityRowText(transaction: transaction, date: formattedDate, walletManager: walletManager, store: paymentLinks)
        let amount = amount(row.xmr)
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                TransactionDisc(systemImage: row.systemImage, tint: iconColor, ringState: ConfirmationRing.state(of: transaction))
                    .paymentLinkBadge(iconColor, isShown: row.showsLinkBadge, symbol: row.badgeSymbol ?? "link")

                // Details
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        // Whole: next to a long amount, "Получено" broke with a
                        // hyphen; the amount column gives way instead. A
                        // link's name can be long: it ends in "…".
                        .fixedSize(horizontal: !row.showsLinkBadge, vertical: true)
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Amount & Status
                TransactionAmountColumn(transaction: transaction, amount: amount, linkStatus: row.linkStatus)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(12)
        }
        .glassButtonStyle()
        .accessibilityIdentifier("wallet.transaction.\(transaction.id)")
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

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .brand
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

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: transaction.timestamp, relativeTo: Date())
    }

}

#Preview {
    let priceService = PriceService()
    let priceHistoryService = PriceHistoryService(priceService: priceService)
    TransactionsPanelView()
        .environmentObject(WalletManager())
        .environmentObject(priceService)
        .environmentObject(priceHistoryService)
        .frame(width: 350, height: 500)
        .padding()
}
