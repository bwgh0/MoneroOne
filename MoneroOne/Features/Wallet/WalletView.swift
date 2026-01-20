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
                            Task {
                                await walletManager.refresh()
                            }
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
                await walletManager.refresh()
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
                VStack(spacing: 12) {
                    if isSyncing {
                        // Still syncing - show syncing message
                        ProgressView()
                            .tint(.orange)
                        Text("Syncing transactions...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Your transactions will appear here once synced")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    } else {
                        // Synced but no transactions
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No transactions yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
        .navigationDestination(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)

                    if transaction.status == .pending {
                        Text("Pending")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(RecentTransactionButtonStyle())
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .orange
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

struct RecentTransactionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    WalletView(selectedTab: .constant(.wallet))
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
