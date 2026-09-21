import SwiftUI

/// Full-height scrollable transaction panel for iPad Command Center
struct TransactionsPanelView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var selectedTransaction: MoneroTransaction?
    var onSeeAll: (() -> Void)?

    private var isSyncing: Bool {
        switch walletManager.syncState {
        case .syncing, .connecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                if !walletManager.transactions.isEmpty {
                    Button {
                        onSeeAll?()
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Transaction list
            if walletManager.transactions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(walletManager.transactions) { transaction in
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
                TransactionDetailView(transaction: transaction)
            }
            .presentationDetents([.fraction(0.75)])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if isSyncing {
                ProgressView()
                    .tint(.orange)
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
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

                // Details
                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.type == .incoming ? "Received" : "Sent")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

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

                    // Status and fiat share one line under the amount, so
                    // the row keeps its height whether or not the fiat
                    // value has loaded yet.
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
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(12)
        }
        .glassButtonStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.type == .incoming ? "Received" : "Sent") \(XMRFormatter.format(transaction.amount)) XMR\(fiatAtTime.map { ", worth \($0) at the time" } ?? ""), \(formattedDate), \(transaction.displayStatusText)")
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .orange
    }

    /// What the amount was worth when the transaction happened, in the
    /// selected currency. Nil until price history has loaded.
    private var fiatAtTime: String? {
        priceHistoryService.fiatValue(xmr: transaction.amount, at: transaction.timestamp)
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
