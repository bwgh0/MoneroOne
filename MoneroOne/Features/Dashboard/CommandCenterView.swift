import SwiftUI

/// Command Center dashboard for regular-width layouts: iPad, and the unfolded
/// iPhone Duo (inner display ≈ 890×640pt usable, so it only fits two columns).
struct CommandCenterView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    @EnvironmentObject var priceAlertService: PriceAlertService
    @State private var showReceive = false
    @State private var showSend = false
    /// All Transactions open: the Activity split takes the dashboard's place.
    @State private var showAllTransactions = false
    /// The split's selected row (`ActivityListItem.id`); nil opens it on
    /// the newest row.
    @State private var activitySelection: String?
    /// How far the edge swipe has dragged the Activity split toward the
    /// trailing edge (0 = fully open).
    @State private var backSwipeOffset: CGFloat = 0
    /// The Activity split is in the hierarchy: from the open until its
    /// close slide ends.
    @State private var isActivityMounted = false
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
        GeometryReader { geometry in
            let width = geometry.size.width
            // How far the split is open: 1 while it shows, less while the
            // edge swipe drags it back.
            let openFraction = width > 0 ? 1 - min(max(backSwipeOffset / width, 0), 1) : 1
            // Past the trailing edge of the window, the Duo's side bar too.
            let hiddenOffset = width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            ZStack {
                // The dashboard stays under the split, so back returns to it
                // as it was. It moves a third of a screen aside, as the page
                // under a navigation push does.
                dashboard
                    .offset(x: showAllTransactions ? -width * 0.3 * openFraction : 0)
                    .allowsHitTesting(!showAllTransactions)
                    .accessibilityHidden(showAllTransactions)
                if isActivityMounted {
                    // The window keeps one bar layout the whole time (the
                    // Duo's vertical bar, as on the dashboard and in
                    // Settings): nothing here or in the split sets it.
                    SlidingHost(
                        content: activitySplit,
                        trailingOffset: showAllTransactions ? backSwipeOffset : hiddenOffset,
                        hiddenOffset: hiddenOffset,
                        selection: activitySelection
                    )
                    .ignoresSafeArea()
                    .swipesBackFromLeadingEdge(
                        offset: $backSwipeOffset,
                        width: width,
                        onBack: { setActivityOpen(false) }
                    )
                    .allowsHitTesting(showAllTransactions)
                    .transition(.identity)
                }
            }
        }
        .onChange(of: walletManager.walletSessionId) { _, _ in
            selectedHistoryPoint = nil
            historyModel = BalanceHistoryModel()
        }
        .onChange(of: showSend) { _, isPresented in
            if isPresented { selectedHistoryPoint = nil }
        }
        .walletTaskSheet(isPresented: $showReceive) {
            ReceiveView()
                .closesForPaymentLink()
        }
        .walletTaskSheet(isPresented: $showSend) {
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
        if isOpen {
            activitySelection = id
            isActivityMounted = true
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35), completionCriteria: .removed) {
            showAllTransactions = isOpen
            backSwipeOffset = 0
        } completion: {
            if !showAllTransactions { isActivityMounted = false }
        }
    }

    /// The split, with what its own hosting controller does not inherit.
    private var activitySplit: some View {
        ActivitySplitView(
            selection: $activitySelection,
            asOf: selectedHistoryPoint?.timestamp,
            historyTransactions: pastTransactions,
            initialFilter: allTransactionsFilter,
            onBack: { setActivityOpen(false) }
        )
        .accessibilityAction(.escape) { setActivityOpen(false) }
        .environmentObject(walletManager)
        .environmentObject(priceService)
        .environmentObject(priceHistoryService)
        .environmentObject(priceAlertService)
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
            // One bar layout for every row, set by the dashboard: a
            // transaction's detail turned the Duo's vertical bar off and a
            // link's did not, so each switch moved the status bar and the
            // tab bar and resized both columns.
            ActivityDetailView(transaction: transaction, horizontalBarsOnDuo: false)
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

// MARK: - Sliding host

/// Holds a screen in its own hosting controller, laid out once at its final
/// frame, and slides it with a layer transform only. SwiftUI moves a
/// UIKit-backed view by its frame (offset, visualEffect and transformEffect
/// alike), so the split crossed the Duo's vertical bar frame by frame and
/// both columns were laid out again on each frame. A layer transform is
/// drawing only: UIKit lays the split out once, at the open.
private struct SlidingHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    /// How far the screen sits toward the trailing edge; 0 = in place.
    let trailingOffset: CGFloat
    /// Out of sight past the trailing edge: where the open starts.
    let hiddenOffset: CGFloat
    /// Read so a new selection reaches the hosted screen.
    let selection: String?

    func makeUIViewController(context: Context) -> SlidingHostController<Content> {
        let controller = SlidingHostController(rootView: content)
        // It comes in from the trailing edge, as a pushed screen does.
        controller.slide(to: physical(hiddenOffset, context), animated: false)
        return controller
    }

    func updateUIViewController(_ controller: SlidingHostController<Content>, context: Context) {
        controller.host.rootView = content
        let transaction = context.transaction
        let animates = !context.environment.accessibilityReduceMotion
            && (controller.isFirstUpdate || (transaction.animation != nil && !transaction.disablesAnimations))
        controller.isFirstUpdate = false
        controller.slide(to: physical(trailingOffset, context), animated: animates)
    }

    private func edgeSign(_ context: Context) -> CGFloat {
        context.environment.layoutDirection == .rightToLeft ? -1 : 1
    }

    private func physical(_ trailing: CGFloat, _ context: Context) -> CGFloat {
        trailing * edgeSign(context)
    }
}

private final class SlidingHostController<Content: View>: UIViewController {
    let host: UIHostingController<Content>
    var isFirstUpdate = true

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = PassThroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        // Under a column that stops below the bars: the split's own page
        // color, as in Settings.
        host.view.backgroundColor = .systemGroupedBackground
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Bounds and center, not frame: the frame of a transformed view is
        // undefined.
        host.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
        host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    /// Moves the hosted screen by `x` points with a layer transform, with
    /// the dashboard's spring (snappy, 0.35 s) when `animated`.
    func slide(to x: CGFloat, animated: Bool) {
        let layer = host.view.layer
        let target = CATransform3DMakeTranslation(x, 0, 0)
        guard !CATransform3DEqualToTransform(layer.transform, target) else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "slide")
        layer.transform = target
        guard animated else { return }
        let spring = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.15)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: target)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "slide")
    }
}

/// Lets touches through where the hosted screen is not.
private final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Edge swipe back

private extension View {
    /// The back swipe for a screen that takes the dashboard's place without
    /// a navigation push: a drag from the leading screen edge pulls it
    /// toward the trailing edge, and a release past a third of the width
    /// (or a flick) goes back, as a pushed screen does.
    func swipesBackFromLeadingEdge(offset: Binding<CGFloat>, width: CGFloat, onBack: @escaping () -> Void) -> some View {
        modifier(LeadingEdgeSwipeBack(offset: offset, width: width, onBack: onBack))
    }
}

private struct LeadingEdgeSwipeBack: ViewModifier {
    @Binding var offset: CGFloat
    let width: CGFloat
    let onBack: () -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // A thin strip over the leading edge catches the drag; it stays put
        // while the screen moves, and it is narrower than the margin before
        // the back button and the row icons.
        content.overlay(alignment: .leading) {
            Color.clear
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { value in
                            offset = max(value.translation.width * sign, 0)
                        }
                        .onEnded { value in
                            let travelled = value.translation.width * sign
                            let projected = value.predictedEndTranslation.width * sign
                            if travelled > width / 3 || projected > width / 2 {
                                onBack()
                            } else {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { offset = 0 }
                            }
                        }
                )
                .accessibilityHidden(true)
        }
    }

    /// Distance toward the trailing edge is positive in either direction.
    private var sign: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }
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
