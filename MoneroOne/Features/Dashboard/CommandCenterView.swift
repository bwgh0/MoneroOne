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
    /// The Activity split is in the hierarchy: from the open until its
    /// close slide ends.
    @State private var isActivityMounted = false
    /// Where the back swipe holds All Transactions and the dashboard
    /// (1 = the split in place); nil when no finger holds them.
    @State private var swipeProgress: CGFloat?
    @State private var slideClock = SlideFrameClock()
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
    /// The root's trailing inset: the window's side bar, which a closing
    /// sheet leaves alone.
    @State private var steadyTrailingInset: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Past the trailing edge of the window, the Duo's side bar too.
            let hiddenOffset = width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            ActivitySlide(
                progress: swipeProgress ?? (showAllTransactions ? 1 : 0),
                isOpen: showAllTransactions,
                isMounted: isActivityMounted,
                clock: slideClock,
                width: width,
                hiddenOffset: hiddenOffset,
                selection: activitySelection,
                onSwipe: followSwipe,
                onSwipeEnd: endSwipe,
                onSplitLaidOut: { slideClock.release() },
                dashboard: dashboard,
                split: activitySplit
            )
        }
        .modifier(SteadyTrailingInset(inset: steadyTrailingInset))
        .background(SteadyTrailingReader { steadyTrailingInset = $0 })
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
            if !isActivityMounted && !reduceMotion {
                // The split comes into the hierarchy out of sight, and the
                // dashboard gives up taps and VoiceOver at the same time.
                // The slide waits until the split has laid out: that turn
                // is the slow one, and in the slide it held the third frame
                // for 130 ms.
                withTransaction(\.disablesAnimations, true) {
                    swipeProgress = nil
                    isActivityMounted = true
                    showAllTransactions = true
                }
                slideClock.prepare(from: 0, to: 1) {}
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // In case the split never reports its layout.
                    slideClock.release()
                }
                return
            }
        }
        animateActivity(open: isOpen)
    }

    /// The slide runs on its own frame clock at the display's top rate:
    /// each frame sets the progress, as the finger does in the back swipe.
    /// SwiftUI's own animation clock gave the slide 60 frames a second.
    ///
    /// All Transactions stays open until the back slide ends: the dashboard
    /// takes taps and VoiceOver, and starts its checks, once the split is
    /// out of sight. Done at the tap, that work held the first frame for
    /// 80 ms on the iPhone Duo, and the slide skipped half its way.
    private func animateActivity(open isOpen: Bool) {
        guard !reduceMotion else {
            slideClock.stop()
            swipeProgress = nil
            showAllTransactions = isOpen
            isActivityMounted = isOpen
            return
        }
        // A second tap while the split lays out: the open is on its way.
        if isOpen && slideClock.isWaiting { return }
        let from = slideClock.progress ?? swipeProgress ?? (showAllTransactions ? 1 : 0)
        withTransaction(\.disablesAnimations, true) {
            swipeProgress = nil
            if isOpen { showAllTransactions = true }
        }
        slideClock.run(from: from, to: isOpen ? 1 : 0) {
            guard !isOpen else { return }
            withTransaction(\.disablesAnimations, true) {
                showAllTransactions = false
                isActivityMounted = false
            }
        }
    }

    /// The back swipe moves both screens with the finger, as under a
    /// navigation pop: the dashboard comes back from a third of a screen
    /// aside as the split goes. Before, the dashboard waited for the
    /// release, and a long swipe showed black between the two.
    private func followSwipe(_ progress: CGFloat) {
        withTransaction(\.disablesAnimations, true) {
            // The swipe starts in place, where the open's run ended.
            slideClock.stop()
            swipeProgress = progress
        }
    }

    /// At the release both screens go on from where the finger left them,
    /// on one spring: back to the dashboard, or back in place.
    private func endSwipe(goesBack: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35), completionCriteria: .removed) {
            swipeProgress = nil
            if goesBack { showAllTransactions = false }
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

// MARK: - Steady trailing inset

/// Keeps the dashboard's trailing inset on the root's value. After Send or
/// Receive closed, the tab content got 12 more for up to 2 s, and the
/// dashboard narrowed and widened again.
private struct SteadyTrailingInset: ViewModifier {
    let inset: CGFloat?

    func body(content: Content) -> some View {
        // One view either way, so the dashboard keeps its state.
        content
            .safeAreaPadding(.trailing, inset ?? 0)
            .ignoresSafeArea(.container, edges: inset == nil ? [] : .trailing)
    }
}

/// Reads the root view controller's trailing safe area inset.
private struct SteadyTrailingReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let root = window?.rootViewController else { return }
            let inset = root.view.safeAreaInsets.right
            guard inset != reported else { return }
            reported = inset
            DispatchQueue.main.async { [weak self] in self?.onChange?(inset) }
        }
    }
}

// MARK: - Sliding host

/// The dashboard and All Transactions, moved by one animated value: 0 is the
/// dashboard, 1 the split in place. Each frame both take their place from
/// the same number, so they move together. Before, the split slid by its
/// own Core Animation spring, which does not wait for the main thread: after
/// a slow first frame it left while the dashboard still sat a third of a
/// screen aside, and the screen showed black beside it.
private struct ActivitySlide<Dashboard: View, Split: View>: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    /// Where the slide goes.
    let isOpen: Bool
    let isMounted: Bool
    /// Holds both screens while it runs, in place of `progress`.
    let clock: SlideFrameClock
    let width: CGFloat
    /// Past the trailing edge of the window, the Duo's side bar too.
    let hiddenOffset: CGFloat
    let selection: String?
    /// The back swipe: the progress under the finger, then the release.
    let onSwipe: (CGFloat) -> Void
    let onSwipeEnd: (_ goesBack: Bool) -> Void
    /// The split has laid out for the first time: the open may start.
    let onSplitLaidOut: () -> Void
    let dashboard: Dashboard
    let split: Split

    var body: some View {
        // Read here, so a frame of the clock updates this view alone.
        let shown = clock.progress ?? progress
        ZStack {
            // The dashboard stays under the split, so back returns to it
            // as it was. It moves a third of a screen aside, as the page
            // under a navigation push does.
            dashboard
                .offset(x: -width * 0.3 * shown)
                .allowsHitTesting(!isOpen)
                .accessibilityHidden(isOpen)
            if isMounted {
                // The window keeps one bar layout the whole time (the
                // Duo's vertical bar, as on the dashboard and in
                // Settings): nothing here or in the split sets it.
                SlidingHost(
                    content: split,
                    trailingOffset: hiddenOffset * (1 - shown),
                    isOpen: isOpen,
                    hiddenOffset: hiddenOffset,
                    selection: selection,
                    onSwipe: onSwipe,
                    onSwipeEnd: onSwipeEnd,
                    onLaidOut: onSplitLaidOut
                )
                .ignoresSafeArea()
                .allowsHitTesting(isOpen)
                .transition(.identity)
            }
        }
    }
}

/// Holds a screen in its own hosting controller, laid out once at its final
/// frame, and slides it with a layer transform only. SwiftUI moves a
/// UIKit-backed view by its frame (offset, visualEffect and transformEffect
/// alike), so the split crossed the Duo's vertical bar frame by frame and
/// both columns were laid out again on each frame. A layer transform is
/// drawing only: UIKit lays the split out once, at the open.
private struct SlidingHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    /// How far the screen sits toward the trailing edge on this frame;
    /// 0 = in place.
    let trailingOffset: CGFloat
    /// Where the slide goes: in place, or out past the trailing edge.
    let isOpen: Bool
    /// Out of sight past the trailing edge: where the open starts.
    let hiddenOffset: CGFloat
    /// Read so a new selection reaches the hosted screen.
    let selection: String?
    /// The back swipe: the progress under the finger (1 = in place).
    let onSwipe: (CGFloat) -> Void
    /// The back swipe let go: true when it goes back to the dashboard.
    let onSwipeEnd: (_ goesBack: Bool) -> Void
    /// The screen has laid out for the first time.
    let onLaidOut: () -> Void

    func makeUIViewController(context: Context) -> SlidingHostController<Content> {
        let controller = SlidingHostController(rootView: content)
        controller.onLaidOut = onLaidOut
        controller.edgeSign = edgeSign(context)
        // It comes in from the trailing edge, as a pushed screen does.
        controller.place(at: physical(hiddenOffset, context))
        return controller
    }

    func updateUIViewController(_ controller: SlidingHostController<Content>, context: Context) {
        let isInPlace = isOpen && trailingOffset == 0
        // The screen updates only while it is in place: a new root view
        // lays the whole split out again, which stalled the first frame
        // of the close.
        if isInPlace && !controller.isDragging {
            controller.setRootView(content)
        }
        controller.setSliding(trailingOffset != (isOpen ? 0 : hiddenOffset))
        let hiddenOffset = max(hiddenOffset, 1)
        let onSwipe = onSwipe
        controller.onSwipe = { travelled in onSwipe(1 - min(travelled / hiddenOffset, 1)) }
        controller.onSwipeEnd = onSwipeEnd
        controller.edgeSign = edgeSign(context)
        // The back swipe starts once the screen is in place, and the
        // screen takes taps only there: not while it slides in or out, as
        // under a navigation push or pop.
        controller.isOpen = isInPlace
        controller.place(at: physical(trailingOffset, context))
    }

    private func edgeSign(_ context: Context) -> CGFloat {
        context.environment.layoutDirection == .rightToLeft ? -1 : 1
    }

    private func physical(_ trailing: CGFloat, _ context: Context) -> CGFloat {
        trailing * edgeSign(context)
    }
}

private final class SlidingHostController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    let host: LayoutReportingHost<Content>
    /// The screen is in place: the back swipe may start, and it takes taps.
    var isOpen = false {
        didSet { (viewIfLoaded as? PassThroughView)?.takesTouches = isOpen }
    }
    /// The screen has laid out for the first time.
    var onLaidOut: (() -> Void)? {
        get { host.onFirstLayout }
        set { host.onFirstLayout = newValue }
    }
    /// The back swipe: points travelled toward the trailing edge.
    var onSwipe: ((CGFloat) -> Void)?
    /// The back swipe let go: true when it goes back to the dashboard.
    var onSwipeEnd: ((Bool) -> Void)?
    /// 1 when the trailing edge is on the right, -1 in right-to-left.
    var edgeSign: CGFloat = 1 {
        didSet { backSwipe.edges = edgeSign < 0 ? .right : .left }
    }
    /// The finger holds the screen: updates from SwiftUI leave it there,
    /// and nothing in the split lays out while the finger moves it.
    private(set) var isDragging = false
    /// The display's top rate (120 Hz) while the screen slides or the
    /// finger holds it: the slide ran at 60 Hz.
    private let frameRate = TopFrameRate()
    private var isSliding = false
    /// The system's back swipe, as a navigation controller has it: a drag
    /// that starts at the leading screen edge.
    private lazy var backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackSwipe(_:)))

    init(rootView: Content) {
        host = LayoutReportingHost(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = PassThroughView()
        view.takesTouches = isOpen
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        // Under a column that stops below the bars: the split's own page
        // color, as in Settings.
        host.view.backgroundColor = .systemGroupedBackground
        view.addSubview(host.view)
        host.didMove(toParent: self)
        backSwipe.edges = edgeSign < 0 ? .right : .left
        backSwipe.delegate = self
        view.addGestureRecognizer(backSwipe)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Bounds and center, not frame: the frame of a transformed view is
        // undefined.
        host.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
        host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    func setRootView(_ rootView: Content) {
        host.rootView = rootView
    }

    func setSliding(_ sliding: Bool) {
        guard sliding != isSliding else { return }
        isSliding = sliding
        if sliding {
            frameRate.start()
        } else {
            frameRate.stop(after: TopFrameRate.settleTime)
        }
    }

    /// Puts the screen at `x` (physical) with a layer transform and no
    /// animation of its own: the slide's frames come from SwiftUI, on the
    /// dashboard's clock.
    func place(at x: CGFloat) {
        guard !isDragging else { return }
        let layer = host.view.layer
        let target = CATransform3DMakeTranslation(x, 0, 0)
        guard !CATransform3DEqualToTransform(layer.transform, target) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
    }

    // MARK: Back swipe

    /// The screen follows the finger toward the trailing edge, one to one:
    /// a drag step moves its layer, and the dashboard comes along through
    /// `onSwipe`; nothing in the split lays out. A release past a third of
    /// the width (or a flick) goes back with the close spring, as a pushed
    /// screen does; else both screens spring back in place.
    @objc private func handleBackSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // Toward the trailing edge is positive in either direction.
        let travelled = max(gesture.translation(in: view).x * edgeSign, 0)
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began { setSliding(true) }
            isDragging = true
            let layer = host.view.layer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeTranslation(travelled * edgeSign, 0, 0)
            CATransaction.commit()
            onSwipe?(travelled)
        case .ended:
            let velocity = gesture.velocity(in: view).x * edgeSign
            let width = max(view.bounds.width, 1)
            let goesBack = travelled > width / 3 || (velocity > 0 && travelled + velocity * 0.2 > width / 2)
            isDragging = false
            onSwipeEnd?(goesBack)
        default:
            isDragging = false
            onSwipeEnd?(false)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isOpen
    }

    /// The split's list, rows and columns wait until the back swipe fails,
    /// as the screens under a navigation controller do.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer.view?.isDescendant(of: host.view) == true
    }
}

/// Steps a slide along the open and close spring, one display frame at a
/// time, at the display's top rate. SwiftUI's own animation of the slide
/// ran at 60 Hz. Only the view that reads `progress` updates per frame.
@Observable
private final class SlideFrameClock {
    /// Where the slide is on this frame, or where its last run ended;
    /// nil once stopped.
    private(set) var progress: CGFloat?
    @ObservationIgnored private let spring = Spring.snappy(duration: 0.35)
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var start: CFTimeInterval?
    @ObservationIgnored private var lastFrame: CFTimeInterval?
    @ObservationIgnored private var from: CGFloat = 0
    @ObservationIgnored private var to: CGFloat = 0
    @ObservationIgnored private var onEnd: (() -> Void)?

    /// A prepared run holds its start until `release()`.
    @ObservationIgnored private(set) var isWaiting = false

    /// Starts from `from` with no speed. A run already going stops where
    /// it is, and its end does not run.
    func run(from: CGFloat, to: CGFloat, onEnd: @escaping () -> Void) {
        prepare(from: from, to: to, onEnd: onEnd)
        release()
    }

    /// Holds the slide at `from` until `release()`, then runs it as `run`
    /// does.
    func prepare(from: CGFloat, to: CGFloat, onEnd: @escaping () -> Void) {
        link?.invalidate()
        link = nil
        self.from = from
        self.to = to
        self.onEnd = onEnd
        start = nil
        lastFrame = nil
        isWaiting = true
        progress = from
    }

    /// Starts the prepared run; nothing when none waits.
    func release() {
        guard isWaiting else { return }
        isWaiting = false
        let target = DisplayLinkTarget { [weak self] in self?.step($0) }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Lets go of the slide, and the end does not run.
    func stop() {
        link?.invalidate()
        link = nil
        onEnd = nil
        isWaiting = false
        if progress != nil { progress = nil }
    }

    private func step(_ link: CADisplayLink) {
        // Time 0 is the frame before the first one the link gets: a slow
        // turn before it delays the slide and skips none of it.
        var start = start ?? link.timestamp
        // A slow turn during the slide holds it too: it goes on one frame
        // further, and skips none of its way.
        let frame = link.targetTimestamp - link.timestamp
        if let lastFrame, link.timestamp - lastFrame > frame * 1.5 {
            start += link.timestamp - lastFrame - frame
        }
        self.start = start
        lastFrame = link.timestamp
        // Where the slide is when this frame shows.
        let time = link.targetTimestamp - start
        // At rest when the spring is within a point of the end: its last
        // tenths of a second move nothing.
        let isAtRest = time >= spring.settlingDuration
            || (time > spring.duration
                && abs(spring.value(target: 1.0, time: time) - 1) < 0.0005
                && abs(spring.velocity(target: 1.0, time: time)) < 0.01)
        if isAtRest {
            link.invalidate()
            self.link = nil
            // It holds the end: cleared, the slide would show where the
            // state says, and an update can read the state from before
            // the end.
            progress = to
            let onEnd = onEnd
            self.onEnd = nil
            onEnd?()
        } else {
            progress = from + (to - from) * CGFloat(spring.value(target: 1.0, time: time))
        }
    }
}

/// Reports the first layout of its screen, once it is in a window: SwiftUI
/// draws the screen in that pass, the slow one of the open.
private final class LayoutReportingHost<Content: View>: UIHostingController<Content> {
    var onFirstLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.window != nil, !view.bounds.isEmpty, let onFirstLayout else { return }
        self.onFirstLayout = nil
        onFirstLayout()
    }
}

/// A display link's target: the link holds it, not the clock.
private final class DisplayLinkTarget: NSObject {
    let onFrame: (CADisplayLink) -> Void

    init(_ onFrame: @escaping (CADisplayLink) -> Void) {
        self.onFrame = onFrame
    }

    @objc func frame(_ link: CADisplayLink) {
        onFrame(link)
    }
}

/// Lets touches through where the hosted screen is not.
private final class PassThroughView: UIView {
    /// False while the screen slides: no touch reaches it.
    var takesTouches = true

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard takesTouches else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
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
