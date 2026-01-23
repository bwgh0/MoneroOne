import SwiftUI

/// iPad Command Center dashboard showing Balance, Price Chart, Transactions, and Quick Actions
struct CommandCenterView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showAllTransactions = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ScrollView {
                if isLandscape {
                    landscapeLayout
                        .padding()
                } else {
                    portraitLayout
                        .padding()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                bannerSection
            }
            .refreshable {
                await walletManager.refresh()
                await priceService.fetchPrice()
            }
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView()
        }
        .sheet(isPresented: $showSend) {
            SendView()
        }
        .sheet(isPresented: $showAllTransactions) {
            NavigationStack {
                TransactionListView()
            }
        }
    }

    // MARK: - Landscape Layout (3 columns)

    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // Column 1: Balance + Quick Actions
            VStack(spacing: 16) {
                // Header
                HStack {
                    DynamicGreeting()
                    Spacer()
                }

                BalanceCard(
                    balance: walletManager.balance,
                    unlockedBalance: walletManager.unlockedBalance,
                    syncState: walletManager.syncState,
                    priceService: priceService,
                    onPriceChangeTap: nil,
                    onCardTap: nil
                )

                QuickActionsCard(
                    onSend: { showSend = true },
                    onReceive: { showReceive = true }
                )

                Spacer()
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            // Column 2: Chart Switcher (Portfolio / Price)
            VStack(spacing: 16) {
                ChartSwitcherCard(balance: walletManager.balance)
                Spacer()
            }
            .frame(minWidth: 320, idealWidth: 400)

            // Column 3: Transactions
            TransactionsPanelView(onSeeAll: {
                showAllTransactions = true
            })
            .frame(minWidth: 300, idealWidth: 350)
        }
    }

    // MARK: - Portrait Layout (2 columns)

    private var portraitLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // Column 1: Balance + Actions + Chart (stacked)
            VStack(spacing: 16) {
                // Header
                HStack {
                    DynamicGreeting()
                    Spacer()
                }

                BalanceCard(
                    balance: walletManager.balance,
                    unlockedBalance: walletManager.unlockedBalance,
                    syncState: walletManager.syncState,
                    priceService: priceService,
                    onPriceChangeTap: nil,
                    onCardTap: nil
                )

                QuickActionsCard(
                    onSend: { showSend = true },
                    onReceive: { showReceive = true }
                )

                ChartSwitcherCard(balance: walletManager.balance)

                Spacer()
            }
            .frame(minWidth: 300)

            // Column 2: Transactions
            TransactionsPanelView(onSeeAll: {
                showAllTransactions = true
            })
            .frame(minWidth: 300, idealWidth: 350)
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var bannerSection: some View {
        VStack(spacing: 8) {
            if walletManager.isTestnet {
                TestnetBanner()
            }
            OfflineBanner()
            SyncErrorBanner(syncState: walletManager.syncState) {
                Task {
                    await walletManager.refresh()
                }
            }
        }
        .padding(.horizontal)
        .animation(.easeInOut, value: walletManager.syncState)
    }
}

#Preview {
    CommandCenterView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
