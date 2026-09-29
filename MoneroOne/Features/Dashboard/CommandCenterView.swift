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
    @State private var hardwareSheetIntent: HardwareSessionSheet.Intent? = nil

    @State private var isHistoryExpanded = false
    @State private var selectedHistoryPoint: PortfolioDataPoint?
    @State private var selectedHistoryRange: ChartTimeRange = .week
    @State private var historyModel = BalanceHistoryModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let columnHeight = max(geometry.size.height - 32, isHistoryExpanded ? 760 : 600)

            ScrollView {
                twoColumnLayout
                    .frame(minHeight: columnHeight)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            // Lets the wallet rows' swipe-to-delete work outside a List (iOS 27).
            .safeAreaInset(edge: .top, spacing: 0) {
                bannerSection
            }
            .refreshable {
                await walletManager.refresh()
                await priceService.fetchPrice()
            }
        }
        .onChange(of: walletManager.walletSessionId) { _, _ in
            selectedHistoryPoint = nil
            historyModel = BalanceHistoryModel()
            isHistoryExpanded = false
        }
        .onChange(of: showSend) { _, isPresented in
            if isPresented { selectedHistoryPoint = nil }
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView()
                .closesForPaymentLink()
        }
        .sheet(isPresented: $showSend) {
            SendFlowView()
        }
        // Donate and `monero:` links ask for Send through the manager. Without
        // this they did nothing on iPad and the unfolded iPhone Duo.
        .presentsSendRequests(from: walletManager, showSend: $showSend)
        .sheet(isPresented: $showAllTransactions) {
            NavigationStack {
                TransactionListView(asOf: selectedHistoryPoint?.timestamp, historyTransactions: pastTransactions)
            }
            .closesForPaymentLink()
        }
        .sheet(item: $hardwareSheetIntent) { intent in
            HardwareSessionSheet(
                intent: intent,
                trezorManager: walletManager.trezorManager
            )
            .environmentObject(walletManager)
        }
    }

    // MARK: - Two Columns (portrait, iPhone Duo unfolded)

    /// Equal columns so the gutter sits on the fold when the Duo is half
    /// open in book pose (HIG: even column counts, nothing straddles the
    /// division region).
    private var twoColumnLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // Wallet balance, its history and actions share one column.
            VStack(spacing: 16) {
                greetingHeader
                if showWalletManager {
                    walletRows
                    Spacer(minLength: 0)
                } else {
                    balanceCard
                    quickActions
                    Spacer(minLength: 0)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: showWalletManager)
            .frame(maxWidth: .infinity)

            // Column 2: Transactions
            transactionsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pieces

    /// The greeting and the chip stay put whether the list is open or not;
    /// only the content below swaps, and that is what shows the open state.
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
            isHardwareWallet: walletManager.isHardwareWallet,
            hardwareDeviceName: walletManager.hardwareDisplayName,
            hardwareLastSentSyncAt: walletManager.lastHardwareSentSyncAt,
            isHardwareDeviceWarm: walletManager.isHardwareDeviceWarm,
            isHistoryExpanded: $isHistoryExpanded,
            selectedHistoryPoint: $selectedHistoryPoint,
            selectedHistoryRange: $selectedHistoryRange,
            historyModel: historyModel,
            onHardwareSyncTap: {
                // Clear a finished run's .complete/.failed state so the sheet
                // opens to a fresh bringup. This stays at the tap site, as in
                // WalletView: SwiftUI can re-fire the sheet's onAppear during
                // state changes, and a reset there could slip past the
                // duplicate-session guard.
                walletManager.clearTerminalSessionState()
                hardwareSheetIntent = .syncSentTransactions
            }
        )
        .id(walletManager.walletSessionId)
    }

    private var quickActions: some View {
        QuickActionsCard(
            onSend: { selectedHistoryPoint = nil; showSend = true },
            onReceive: { selectedHistoryPoint = nil; showReceive = true },
            // canSend: `isViewOnly` is true for a hardware wallet too, and
            // its device signs the send.
            isSendDisabled: !walletManager.canSend
        )
    }

    private var transactionsPanel: some View {
        TransactionsPanelView(
            onSeeAll: { showAllTransactions = true },
            asOf: selectedHistoryPoint?.timestamp,
            historyTransactions: pastTransactions
        )
        .dashboardCard()
    }

    /// The full history behind a past point. Read only in the past, so
    /// loading history does not redraw the panel at Now.
    private var pastTransactions: [MoneroTransaction]? {
        selectedHistoryPoint == nil ? nil : historyModel.ledger?.transactions
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
