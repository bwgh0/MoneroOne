import SwiftUI

/// Command Center dashboard for regular-width layouts: iPad, and the unfolded
/// iPhone Duo (inner display ≈ 890×640pt usable, so it only fits two columns).
struct CommandCenterView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false
    /// All Transactions open: the Activity split takes the dashboard's place.
    @State private var showAllTransactions = false
    /// The split's selected row (`ActivityListItem.id`); nil opens it on
    /// the newest row.
    @State private var activitySelection: String?
    /// All Transactions opens on this filter: Links from the balance
    /// card's open-link lines, else All.
    @State private var allTransactionsFilter: TransactionListView.FilterType = .all
    @ObservedObject private var paymentLinks = EnvelopeStore.shared
    /// Wallet switcher expanded: the wallet rows slide in under the switcher
    /// pill, in place of the Activity column (WalletView's slide on iPhone).
    @State private var showWalletManager = false
    @State private var hardwareSheetIntent: HardwareSessionSheet.Intent? = nil
    @State private var whatsNewEntry: WhatsNewEntry?

    /// The chart card's selected point: the balance card and Activity show
    /// that moment while it is set.
    @State private var selectedHistoryPoint: PortfolioDataPoint?
    @State private var selectedHistoryRange: ChartTimeRange = .week
    @State private var historyModel = BalanceHistoryModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showAllTransactions {
                ActivitySplitView(
                    selection: $activitySelection,
                    asOf: selectedHistoryPoint?.timestamp,
                    historyTransactions: pastTransactions,
                    initialFilter: allTransactionsFilter,
                    onBack: { setActivityOpen(false) }
                )
                .transition(.move(edge: .trailing))
            } else {
                dashboard
                    .transition(.move(edge: .leading))
            }
        }
        .onChange(of: walletManager.walletSessionId) { _, _ in
            selectedHistoryPoint = nil
            historyModel = BalanceHistoryModel()
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
        .sheet(item: $hardwareSheetIntent) { intent in
            HardwareSessionSheet(
                intent: intent,
                trezorManager: walletManager.trezorManager
            )
            .environmentObject(walletManager)
        }
    }

    /// Opens All Transactions as a split (list beside the selected payment,
    /// as Mail), or brings the dashboard back. The slide reads as a push.
    private func setActivityOpen(_ isOpen: Bool, selecting id: String? = nil) {
        if isOpen { activitySelection = id }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) {
            showAllTransactions = isOpen
        }
    }

    private var dashboard: some View {
        GeometryReader { geometry in
            // The visible height under the 16pt padding above and below.
            let columnHeight = max(geometry.size.height - 32, 0)

            ScrollView {
                // The scroll view offers no height, so this one goes to the
                // columns: Activity scrolls inside it and the chart takes
                // the rest of the left column, and both end on one line at
                // the bottom of the screen. A minHeight frame passed no
                // height on: Activity grew to its whole list, and the chart
                // stretched with it past the screen. When the left column
                // needs more (large text, a short window), the page scrolls.
                twoColumnLayout
                    .frame(idealHeight: columnHeight, alignment: .top)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .refreshable {
                await walletManager.refresh()
                await priceService.fetchPrice()
            }
            // Looks at sent links on new blocks, so a claimed link leaves
            // the balance card's line. Never on a past point or a sheet.
            .checksOpenPaymentLinks(isActive: selectedHistoryPoint == nil
                                    && !showSend && !showReceive && !showAllTransactions && !showWalletManager)
            .requestsReviewAfterSend(isIdle: walletManager.isUnlocked && selectedHistoryPoint == nil
                                     && !showSend && !showReceive
                                     && !showAllTransactions && !showWalletManager && hardwareSheetIntent == nil)
        }
    }

    // MARK: - Two Columns (portrait, iPhone Duo unfolded)

    /// The header spans both columns, so the wallet switcher sits at the top
    /// trailing corner (beside the vertical bar on the unfolded iPhone Duo),
    /// and its rows open right below it, in place of Activity, while the
    /// balance column stays. The balance history chart fills the rest of
    /// that column, so both columns end on one line.
    ///
    /// Equal columns so the gutter sits on the fold when the Duo is half
    /// open in book pose (HIG: even column counts, nothing straddles the
    /// division region).
    private var twoColumnLayout: some View {
        // The first card sits 12 under the header, as on iPhone.
        VStack(spacing: 12) {
            header

            HStack(alignment: .top, spacing: 16) {
                // Wallet balance, actions and history share one column.
                VStack(spacing: 16) {
                    balanceCard
                    quickActions
                    historyCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Column 2: Activity, or the wallet rows under the switcher.
                VStack(spacing: 0) {
                    if showWalletManager {
                        walletRows
                        Spacer(minLength: 0)
                    } else {
                        transactionsPanel
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: showWalletManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Pieces

    /// The greeting and the chip stay put whether the list is open or not;
    /// only the content below the chip swaps, and that is what shows the
    /// open state. The row spans the whole dashboard width. Banners stack
    /// under it 8 apart, as on iPhone.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                DynamicGreeting()
                Spacer(minLength: 12)
                WalletSwitcherButton(isExpanded: $showWalletManager, isInline: true)
                    .environmentObject(walletManager)
            }

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
            WhatsNewBannerSlot(presented: $whatsNewEntry)
        }
        .animation(.easeInOut, value: walletManager.syncState)
        .whatsNewHome(presented: $whatsNewEntry)
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
            hasInlineHistory: false,
            selectedHistoryPoint: $selectedHistoryPoint,
            selectedHistoryRange: $selectedHistoryRange,
            historyModel: historyModel,
            openLinks: OpenPaymentLinks.summary(
                of: paymentLinks.records,
                activeWalletId: walletManager.activeWallet?.id.uuidString,
                walletIds: walletManager.walletIds
            ),
            onOpenLinks: {
                allTransactionsFilter = .links
                setActivityOpen(true)
            },
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

    /// The balance history, open on regular width: the chart the balance
    /// card's History button shows on iPhone, in a card of its own that
    /// fills the column. A scrub shows that moment in the balance card and
    /// in Activity, as on iPhone.
    private var historyCard: some View {
        BalanceHistoryChart(
            balance: walletManager.displayBalance,
            isActive: true,
            model: historyModel,
            priceService: priceService,
            selectedTimeRange: $selectedHistoryRange,
            selectedPoint: $selectedHistoryPoint,
            fillsHeight: true
        )
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardCard()
        // A new wallet gets a new chart, so it loads that wallet's ledger.
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
            onSeeAll: {
                allTransactionsFilter = .all
                setActivityOpen(true)
            },
            onSelect: { transaction in
                allTransactionsFilter = .all
                setActivityOpen(true, selecting: ActivityListItem.transaction(transaction).id)
            },
            isHistoryOpen: selectedHistoryPoint != nil,
            asOf: selectedHistoryPoint?.timestamp,
            historyTransactions: pastTransactions
        )
    }

    /// The full history behind a past point. Read only in the past, so
    /// loading history does not redraw the panel at Now.
    private var pastTransactions: [MoneroTransaction]? {
        selectedHistoryPoint == nil ? nil : historyModel.ledger?.transactions
    }
}

// MARK: - Activity split

/// All Transactions on regular width (iPad, the open iPhone Duo): the list
/// beside the selected payment, as Mail shows a mailbox beside a message.
/// The list column keeps its search, filter and summary; the detail column
/// shows what a row pushes on iPhone. The back glyph brings the dashboard
/// back.
struct ActivitySplitView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var paymentLinks = EnvelopeStore.shared
    @Binding var selection: String?
    let asOf: Date?
    let historyTransactions: [MoneroTransaction]?
    let initialFilter: TransactionListView.FilterType
    let onBack: () -> Void

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            TransactionListView(
                asOf: asOf,
                historyTransactions: historyTransactions,
                initialFilter: initialFilter,
                selection: $selection
            )
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
        } detail: {
            NavigationStack {
                detail
            }
            // A new selection starts the column at its root, as Mail does.
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedItem {
        case .transaction(let transaction):
            ActivityDetailView(transaction: transaction)
        case .openSent(let record):
            PaymentLinkDetailView(recordId: record.id, role: .sent)
        case .linkToClaim, nil:
            // Nothing selected (an empty list): a blank column.
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
        }
    }

    /// The selected row, read from the live list so a new confirmation
    /// shows in the detail column.
    private var selectedItem: ActivityListItem? {
        guard let selection else { return nil }
        let source = asOf == nil ? walletManager.mergedTransactions : (historyTransactions ?? walletManager.mergedTransactions)
        if let transaction = source.first(where: { ActivityListItem.transaction($0).id == selection }) {
            return .transaction(transaction)
        }
        if let record = paymentLinks.records.first(where: { ActivityListItem.openSent($0).id == selection }) {
            return .openSent(record)
        }
        return nil
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
