import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @ObservedObject private var trustedLocationSync = TrustedLocationSyncManager.shared
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
                            isSyncBlocked: trustedLocationSync.isSyncBlocked,
                            isOutsideTrustedZone: trustedLocationSync.isOutsideTrustedZone,
                            trustedLocationName: trustedLocationSync.currentTrustedLocationName,
                            isTrustedLocationEnabled: trustedLocationSync.isEnabled,
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
                            .accessibilityLabel("Send Monero")
                            .accessibilityHint("Opens the send transaction screen")

                            CompactActionButton(
                                title: "Receive",
                                icon: "arrow.down.circle.fill",
                                color: .green
                            ) {
                                showReceive = true
                            }
                            .accessibilityIdentifier("wallet.receiveButton")
                            .accessibilityLabel("Receive Monero")
                            .accessibilityHint("Opens the receive screen with your address and QR code")
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: showWalletManager ? 0 : nil)
                    .scaleEffect(y: showWalletManager ? 0.01 : 1, anchor: .top)
                    .opacity(showWalletManager ? 0 : 1)
                    .allowsHitTesting(!showWalletManager)

                    // Recent transactions — hide instantly, no animation
                    if !showWalletManager {
                        RecentTransactionsSection()
                            .padding(.horizontal)
                            .padding(.top, 16)
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
            .walletHeader(showWalletManager: $showWalletManager)
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
                SendFlowView()
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
                            ProgressView()
                                .tint(.orange)
                                .accessibilityHidden(true)
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
                                .accessibilityHidden(true)
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
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

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

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(transaction.type == .incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)

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
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(14)
        }
        .glassButtonStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.type == .incoming ? "Received" : "Sent") \(XMRFormatter.format(transaction.amount)) XMR, \(formattedDate), \(transaction.displayStatusText)")
        .accessibilityHint("Shows transaction details")
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

// MARK: - Wallet Header (iOS version compat)

private struct WalletHeaderContent: View {
    @Binding var showWalletManager: Bool
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        VStack(spacing: 8) {
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

            if walletManager.isTestnet {
                TestnetBanner()
                    .padding(.horizontal)
                    .accessibilityLabel("Testnet mode active, test XMR only")
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
}

private extension View {
    @ViewBuilder
    func walletHeader(showWalletManager: Binding<Bool>) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .top, spacing: 12) {
                WalletHeaderContent(showWalletManager: showWalletManager)
            }
        } else {
            self.safeAreaInset(edge: .top, spacing: 12) {
                WalletHeaderContent(showWalletManager: showWalletManager)
            }
        }
    }
}

#Preview {
    WalletView(selectedTab: .constant(.wallet))
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
