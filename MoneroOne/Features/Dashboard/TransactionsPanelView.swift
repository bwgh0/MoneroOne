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
                    Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(statusColor)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(12)
        }
        .glassButtonStyle()
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .orange
    }

    private var statusText: String {
        if transaction.status == .failed {
            return "Failed"
        }
        let confs = transaction.confirmations
        if confs == 0 {
            return "Pending"
        } else if confs < 10 {
            return "Locked"
        } else {
            return "Confirmed"
        }
    }

    private var statusColor: Color {
        if transaction.status == .failed {
            return .red
        }
        let confs = transaction.confirmations
        if confs == 0 {
            return .orange
        } else if confs < 10 {
            return .orange
        } else {
            return .green
        }
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: transaction.timestamp, relativeTo: Date())
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}

#Preview {
    TransactionsPanelView()
        .environmentObject(WalletManager())
        .frame(width: 350, height: 500)
        .padding()
}
