import SwiftUI

/// Command Center dashboard for regular-width layouts: iPad, and the unfolded
/// iPhone Duo (inner display ≈ 890×640pt usable, so it only fits two columns).
struct CommandCenterView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showAllTransactions = false
    /// Wallet switcher expanded: the greeting slides out, the switcher pill
    /// stretches, and the wallet rows replace the balance column (same
    /// choreography as WalletView on iPhone).
    @State private var showWalletManager = false

    /// Below this width (iPad portrait, iPhone Duo unfolded) the chart stacks
    /// under the balance instead of taking its own column.
    private let threeColumnMinWidth: CGFloat = 1000

    /// Shortest column height that still shows every card at full size. The
    /// columns are sized to the viewport when it is taller, and scroll when
    /// it is shorter. Two columns stack the chart card under the balance, so
    /// they need more room.
    private let twoColumnMinHeight: CGFloat = 600
    private let threeColumnMinHeight: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            let useThreeColumns = geometry.size.width >= threeColumnMinWidth
                && geometry.size.width > geometry.size.height
            let minHeight = useThreeColumns ? threeColumnMinHeight : twoColumnMinHeight
            // Fill the viewport so the cards stretch to the bottom edge instead
            // of stacking at the top with dead space below them.
            let columnHeight = max(geometry.size.height - 32, minHeight)

            ScrollView {
                Group {
                    if useThreeColumns {
                        threeColumnLayout
                    } else {
                        twoColumnLayout
                    }
                }
                .frame(height: columnHeight)
                .padding()
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
            SendFlowView()
        }
        .sheet(isPresented: $showAllTransactions) {
            NavigationStack {
                TransactionListView()
            }
        }
    }

    // MARK: - Three Columns (wide landscape)

    private var threeColumnLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // Column 1: Balance + Quick Actions (or the wallet rows)
            VStack(spacing: 16) {
                greetingHeader
                if showWalletManager {
                    walletRows
                } else {
                    balanceCard
                    quickActions
                }
                Spacer(minLength: 0)
            }
            .animation(.snappy(duration: 0.4), value: showWalletManager)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            // Column 2: Chart Switcher (Portfolio / Price)
            ChartSwitcherCard(balance: walletManager.displayBalance)
                .frame(minWidth: 300, idealWidth: 400, maxHeight: .infinity)

            // Column 3: Transactions
            transactionsPanel
                .frame(minWidth: 300, idealWidth: 350, maxHeight: .infinity)
        }
    }

    // MARK: - Two Columns (portrait, iPhone Duo unfolded)

    /// Equal columns so the gutter sits on the fold when the Duo is half
    /// open in book pose (HIG: even column counts, nothing straddles the
    /// division region).
    private var twoColumnLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // Column 1: Balance + Actions + Chart (stacked, chart takes the rest)
            VStack(spacing: 16) {
                greetingHeader
                if showWalletManager {
                    walletRows
                    Spacer(minLength: 0)
                } else {
                    balanceCard
                    quickActions
                    ChartSwitcherCard(balance: walletManager.displayBalance)
                        .frame(maxHeight: .infinity)
                }
            }
            .animation(.snappy(duration: 0.4), value: showWalletManager)
            .frame(maxWidth: .infinity)

            // Column 2: Transactions
            transactionsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pieces

    /// The greeting and the chip stay put whether the list is open or not;
    /// only the content below swaps. The chip's ring shows the open state.
    private var greetingHeader: some View {
        HStack(spacing: 0) {
            DynamicGreeting()
            Spacer(minLength: 12)
            WalletSwitcherButton(isExpanded: $showWalletManager)
                .environmentObject(walletManager)
        }
    }

    private var walletRows: some View {
        WalletManagerRows(isExpanded: $showWalletManager)
            // Rows carry the phone's 16pt screen inset; the column already
            // has it, so pull them back flush with the switcher pill.
            .padding(.horizontal, -16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var balanceCard: some View {
        BalanceCard(
            balance: walletManager.displayBalance,
            unlockedBalance: walletManager.displayUnlockedBalance,
            syncState: walletManager.syncState,
            connectionStage: walletManager.connectionStage,
            priceService: priceService,
            isViewOnly: walletManager.isViewOnly,
            onPriceChangeTap: nil,
            onCardTap: nil
        )
    }

    private var quickActions: some View {
        QuickActionsCard(
            onSend: { showSend = true },
            onReceive: { showReceive = true },
            isSendDisabled: walletManager.isViewOnly
        )
    }

    private var transactionsPanel: some View {
        TransactionsPanelView(onSeeAll: {
            showAllTransactions = true
        })
        .dashboardCard()
    }

    // MARK: - Banners

    @ViewBuilder
    private var bannerSection: some View {
        VStack(spacing: 8) {
            if walletManager.isTestnet {
                TestnetBanner()
                    .accessibilityLabel("Testnet mode active")
            }
            OfflineBanner()
            SyncErrorBanner(syncState: walletManager.syncState) {
                Task {
                    await walletManager.refresh()
                }
            }
            if walletManager.showsEmptyRestoreHint {
                RestoreHeightHintBanner(restoreHeight: walletManager.activeWallet?.restoreHeight ?? 0) {
                    walletManager.dismissEmptyRestoreHint()
                }
            }
        }
        .padding(.horizontal)
        .animation(.easeInOut, value: walletManager.syncState)
        .animation(.easeInOut, value: walletManager.showsEmptyRestoreHint)
    }
}

// MARK: - Card chrome

/// Card background shared by the dashboard panels, matching BalanceCard so the
/// chart and transactions read as panels instead of floating text.
struct DashboardCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(DashboardCardModifier())
    }
}

#Preview {
    CommandCenterView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
