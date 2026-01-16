import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false
    @Binding var selectedTab: MainTabView.Tab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header with wallet icon and greeting
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            DynamicGreeting()
                        }
                        Spacer()
                        // Wallet switcher button
                        Button {
                            // Future: wallet switching
                        } label: {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.horizontal)

                    // Testnet Banner
                    if walletManager.isTestnet {
                        TestnetBanner()
                            .padding(.horizontal)
                    }

                    // Error Banners
                    VStack(spacing: 8) {
                        OfflineBanner()
                        SyncErrorBanner(syncState: walletManager.syncState) {
                            walletManager.refresh()
                        }
                    }
                    .padding(.horizontal)
                    .animation(.easeInOut, value: walletManager.syncState)

                    // Balance Card
                    BalanceCard(
                        balance: walletManager.balance,
                        unlockedBalance: walletManager.unlockedBalance,
                        syncState: walletManager.syncState,
                        priceService: priceService,
                        onPriceChangeTap: {
                            selectedTab = .chart
                        }
                    )
                    .padding(.horizontal)

                    // Action Buttons (compact)
                    HStack(spacing: 16) {
                        CompactActionButton(
                            title: "Send",
                            icon: "arrow.up.circle.fill",
                            color: .orange
                        ) {
                            showSend = true
                        }

                        CompactActionButton(
                            title: "Receive",
                            icon: "arrow.down.circle.fill",
                            color: .green
                        ) {
                            showReceive = true
                        }
                    }
                    .padding(.horizontal)

                    Spacer()
                        .frame(height: 8)

                    // Recent Transactions
                    RecentTransactionsSection()
                        .padding(.horizontal)
                }
                .padding(.top)
            }
            .navigationBarHidden(true)
            .refreshable {
                walletManager.refresh()
                await priceService.fetchPrice()
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView()
            }
            .sheet(isPresented: $showSend) {
                SendView()
            }
        }
    }
}

struct TestnetBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "flask.fill")
                .foregroundStyle(.white)
            Text("Testnet Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("Test XMR only")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cyan.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .buttonStyle(.glass)
    }
}

/// Compact action button with reduced height
struct CompactActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.glass)
    }
}

/// Recent transactions section for homepage
struct RecentTransactionsSection: View {
    @EnvironmentObject var walletManager: WalletManager

    private var recentTransactions: [MoneroTransaction] {
        Array(walletManager.transactions.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                if !walletManager.transactions.isEmpty {
                    NavigationLink {
                        FullTransactionListView()
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }

            if recentTransactions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("No transactions yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentTransactions) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            CompactTransactionRow(transaction: transaction)
                        }
                        .buttonStyle(.plain)

                        if transaction.id != recentTransactions.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
}

/// Compact transaction row for homepage
struct CompactTransactionRow: View {
    let transaction: MoneroTransaction

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.subheadline)
                .foregroundColor(transaction.type == .incoming ? .green : .orange)
                .frame(width: 32, height: 32)
                .background(
                    (transaction.type == .incoming ? Color.green : Color.orange)
                        .opacity(0.15)
                )
                .cornerRadius(8)

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

            // Amount
            Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(transaction.type == .incoming ? .green : .primary)
        }
        .padding(.vertical, 8)
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

/// Full transaction list view (accessible from "See All")
struct FullTransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        List {
            ForEach(walletManager.transactions) { transaction in
                NavigationLink {
                    TransactionDetailView(transaction: transaction)
                } label: {
                    TransactionRow(transaction: transaction)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("All Transactions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    WalletView(selectedTab: .constant(.wallet))
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
