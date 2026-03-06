import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showPortfolio = false
    @State private var showWalletManager = false
    @Binding var selectedTab: MainTabView.Tab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // Balance + actions — collapse upward
                    VStack(spacing: 16) {
                        BalanceCard(
                            balance: walletManager.balance,
                            unlockedBalance: walletManager.unlockedBalance,
                            syncState: walletManager.syncState,
                            connectionStage: walletManager.connectionStage,
                            priceService: priceService,
                            onPriceChangeTap: {
                                selectedTab = .chart
                            },
                            onCardTap: {
                                showPortfolio = true
                            }
                        )
                        .padding(.horizontal)

                        HStack(spacing: 16) {
                            CompactActionButton(
                                title: "Send",
                                icon: "arrow.up.circle.fill",
                                color: .orange
                            ) {
                                showSend = true
                            }
                            .accessibilityIdentifier("wallet.sendButton")

                            CompactActionButton(
                                title: "Receive",
                                icon: "arrow.down.circle.fill",
                                color: .green
                            ) {
                                showReceive = true
                            }
                            .accessibilityIdentifier("wallet.receiveButton")
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: showWalletManager ? 0 : nil)
                    .scaleEffect(y: showWalletManager ? 0.01 : 1, anchor: .top)
                    .opacity(showWalletManager ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!showWalletManager)

                    // Recent transactions — hide instantly, no animation
                    if !showWalletManager {
                        RecentTransactionsSection()
                            .padding(.horizontal)
                            .transaction { $0.animation = nil }
                    }

                    // Wallet rows — slide in from the right
                    if showWalletManager {
                        WalletManagerRows(isExpanded: $showWalletManager)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.4), value: showWalletManager)
            .safeAreaBar(edge: .top, spacing: 12) {
                // Floating header with progressive blur - content scrolls underneath
                VStack(spacing: 8) {
                    // Top row: Greeting on left, Wallet switcher on right
                    HStack(spacing: 0) {
                        if !showWalletManager {
                            DynamicGreeting()
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            Spacer(minLength: 12)
                        }

                        WalletSwitcherButton(isExpanded: $showWalletManager)
                            .environmentObject(walletManager)
                            .frame(maxWidth: showWalletManager ? .infinity : nil)
                    }
                    .animation(.snappy(duration: 0.35), value: showWalletManager)
                    .padding(.horizontal)

                    // Banners below the header
                    if walletManager.isTestnet {
                        TestnetBanner()
                            .padding(.horizontal)
                    }

                    OfflineBanner()
                        .padding(.horizontal)

                    SyncErrorBanner(syncState: walletManager.syncState) {
                        Task {
                            await walletManager.refresh()
                        }
                    }
                    .padding(.horizontal)
                }
                .animation(.easeInOut, value: walletManager.syncState)
            }
            .refreshable {
                await walletManager.refresh()
                await priceService.fetchPrice()
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView()
                    .environmentObject(walletManager)
                    .environmentObject(priceService)
            }
            .sheet(isPresented: $showSend) {
                SendView()
                    .environmentObject(walletManager)
                    .environmentObject(priceService)
            }
            .onChange(of: walletManager.shouldShowSendView) { show in
                if show {
                    showSend = true
                    walletManager.shouldShowSendView = false
                }
            }
            .sheet(isPresented: $showPortfolio) {
                PortfolioChartView(
                    balance: walletManager.balance,
                    priceService: priceService
                )
                .environmentObject(walletManager)
                .environmentObject(priceService)
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
        .glassButtonStyle()
    }
}

/// Recent transactions section for homepage
struct RecentTransactionsSection: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var selectedTransaction: MoneroTransaction?

    private var recentTransactions: [MoneroTransaction] {
        Array(walletManager.transactions.prefix(5))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                if !walletManager.transactions.isEmpty {
                    NavigationLink {
                        TransactionListView()
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }

            if recentTransactions.isEmpty {
                Button(action: {}) {
                    VStack(spacing: 12) {
                        if isSyncing {
                            // Still syncing - show syncing message
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
                            // Synced but no transactions
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No transactions yet")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
                .glassButtonStyle()
                .disabled(true)
            } else {
                VStack(spacing: 8) {
                    ForEach(recentTransactions) { transaction in
                        RecentTransactionCard(transaction: transaction) {
                            selectedTransaction = transaction
                        }
                    }
                }
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
}

/// Liquid glass transaction card for home page
struct RecentTransactionCard: View {
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
                    Text("\(transaction.type == .incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)

                    // Status indicator with dot
                    HStack(spacing: 4) {
                        Circle()
                            .fill(transaction.displayStatusColor)
                            .frame(width: 6, height: 6)
                        Text(transaction.displayStatusText)
                            .font(.caption2)
                            .foregroundColor(transaction.displayStatusColor)
                    }
                }

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(14)
        }
        .glassButtonStyle()
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .orange
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: transaction.timestamp, relativeTo: Date())
    }

}

#Preview {
    WalletView(selectedTab: .constant(.wallet))
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
