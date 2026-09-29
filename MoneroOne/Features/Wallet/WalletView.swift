import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @ObservedObject private var trustedLocationSync = TrustedLocationSyncManager.shared
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showWalletManager = false
    @State private var hardwareSheetIntent: HardwareSessionSheet.Intent? = nil
    @State private var isHistoryExpanded = false
    @State private var selectedHistoryPoint: PortfolioDataPoint?
    @State private var selectedHistoryRange: ChartTimeRange = .week
    @State private var historyModel = BalanceHistoryModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Viewport and above-activity heights, so the empty activity card can
    /// fill the leftover height on short screens (iPhone Duo cover).
    @State private var viewportHeight: CGFloat = 0
    @State private var aboveRecentHeight: CGFloat = 0

    /// Height the empty activity card needs to reach the bottom of the
    /// viewport, so short screens don't end in a blank third. Nil when there
    /// is no meaningful space to fill.
    private var recentFillHeight: CGFloat? {
        guard viewportHeight > 0, aboveRecentHeight > 0 else { return nil }
        // top padding 16 + stack spacing 8 + section header 24 + spacing 12 + bottom 16
        let remaining = viewportHeight - aboveRecentHeight - 76
        return remaining > 160 ? remaining : nil
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            CompactActionButton(
                title: "Send",
                icon: "arrow.up.circle.fill",
                color: .brand,
                isDisabled: !walletManager.canSend
            ) {
                selectedHistoryPoint = nil
                showSend = true
            }
            .accessibilityIdentifier("wallet.sendButton")
            .accessibilityLabel(walletManager.canSend ? "Send Monero" : "Send Monero, disabled for view-only wallet")
            .accessibilityHint(walletManager.canSend ? "Opens the send transaction screen" : "This wallet is view-only and cannot send")

            CompactActionButton(
                title: "Receive",
                icon: "arrow.down.circle.fill",
                color: .green
            ) {
                selectedHistoryPoint = nil
                showReceive = true
            }
            .accessibilityIdentifier("wallet.receiveButton")
            .accessibilityLabel("Receive Monero")
            .accessibilityHint("Opens the receive screen with your address and QR code")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // Balance + actions — collapse upward
                    VStack(spacing: 16) {
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
                            isSyncBlocked: trustedLocationSync.isSyncBlocked,
                            isOutsideTrustedZone: trustedLocationSync.isOutsideTrustedZone,
                            trustedLocationName: trustedLocationSync.currentTrustedLocationName,
                            isTrustedLocationEnabled: trustedLocationSync.isEnabled,
                            isHistoryExpanded: $isHistoryExpanded,
                            selectedHistoryPoint: $selectedHistoryPoint,
                            selectedHistoryRange: $selectedHistoryRange,
                            historyModel: historyModel,
                            onHardwareSyncTap: {
                                // Clear any leftover .complete/.failed
                                // state from the prior run so the
                                // sheet opens to a fresh bringup, not
                                // to a stale success/failure view.
                                // Done at the tap site (not in sheet
                                // onAppear) so SwiftUI re-firing
                                // onAppear during state transitions
                                // doesn't sneak through the duplicate-
                                // session guard.
                                walletManager.clearTerminalSessionState()
                                hardwareSheetIntent = .syncSentTransactions
                            }
                        )
                        .id(walletManager.walletSessionId)
                        .padding(.horizontal)

                        actionButtons
                            .padding(.horizontal)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { aboveRecentHeight = $0 }
                    .frame(height: showWalletManager ? 0 : nil)
                    .scaleEffect(y: showWalletManager ? 0.01 : 1, anchor: .top)
                    .opacity(showWalletManager ? 0 : 1)
                    .allowsHitTesting(!showWalletManager)

                    // Recent transactions — hide instantly, no animation
                    if !showWalletManager {
                        RecentTransactionsSection(
                            emptyStateMinHeight: recentFillHeight,
                            isHistoryOpen: isHistoryExpanded,
                            asOf: selectedHistoryPoint?.timestamp,
                            // Read only in the past, so loading history does
                            // not redraw the list at Now.
                            historyTransactions: selectedHistoryPoint == nil ? nil : historyModel.ledger?.transactions
                        )
                            .padding(.horizontal)
                            .padding(.top, 16)
                            // Moves with the card when History opens or
                            // closes; every other change lands at once.
                            .transaction { if !$0.isHistoryDisclosure { $0.animation = nil } }
                    }

                    // Wallet rows — slide in from the right
                    if showWalletManager {
                        WalletManagerRows(isExpanded: $showWalletManager)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Lets the wallet rows' swipe-to-delete work outside a List (iOS 27).
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: showWalletManager)
            // Viewport below the header bar and above the tab bar (background
            // content respects safe areas), used to size the activity card.
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            }
            .walletHeader(showWalletManager: $showWalletManager)
            .onChange(of: walletManager.walletSessionId) { _, _ in
                selectedHistoryPoint = nil
                historyModel = BalanceHistoryModel()
                isHistoryExpanded = false
            }
            .onChange(of: showSend) { _, isPresented in
                if isPresented { selectedHistoryPoint = nil }
            }
            .refreshable {
                await walletManager.refresh()
                await priceService.fetchPrice()
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView()
                    .environmentObject(walletManager)
                    .environmentObject(priceService)
                    .closesForPaymentLink()
            }
            .sheet(isPresented: $showSend) {
                SendFlowView()
                    .environmentObject(walletManager)
                    .environmentObject(priceService)
            }
            .presentsSendRequests(from: walletManager, showSend: $showSend)
            .sheet(item: $hardwareSheetIntent) { intent in
                HardwareSessionSheet(
                    intent: intent,
                    trezorManager: walletManager.trezorManager
                )
                .environmentObject(walletManager)
            }
        }
    }
}

/// A caution banner like `ErrorBanner(type: .warning)`: yellow glyph,
/// label-color text, yellow tint at 15%.
struct TestnetBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flask.fill")
                .font(.body)
                .foregroundStyle(.yellow)
            Text("Testnet Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("Test XMR only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Compact action button with reduced height
struct CompactActionButton: View {
    let title: LocalizedStringResource
    let icon: String
    let color: Color
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.6) : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

/// Recent transactions section for homepage
struct RecentTransactionsSection: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var selectedTransaction: MoneroTransaction?
    /// Stretches the empty-state card to this height so it reaches the
    /// bottom of the screen instead of leaving a blank block under it.
    var emptyStateMinHeight: CGFloat? = nil
    /// Shows the "As of" line for as long as History is open, so it
    /// arrives with the chart and scrubbing never moves the rows below.
    var isHistoryOpen = false
    var asOf: Date? = nil
    var historyTransactions: [MoneroTransaction]? = nil

    /// The newest five at `asOf` (`TransactionListLogic.through`). It stops
    /// at the fifth match, so scrubbing far back does not copy the whole
    /// history on every frame. Read once per render.
    private var recentTransactions: [MoneroTransaction] {
        let source = asOf == nil ? walletManager.mergedTransactions : (historyTransactions ?? walletManager.mergedTransactions)
        guard let asOf else { return Array(source.prefix(5)) }
        return Array(source.lazy.filter { $0.timestamp <= asOf }.prefix(5))
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
        let recentTransactions = self.recentTransactions
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Activity")
                        .font(.headline)
                    if isHistoryOpen {
                        ActivityAsOfText(asOf: asOf)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wallet.activityHeader")
                Spacer()
                if !recentTransactions.isEmpty {
                    NavigationLink {
                        TransactionListView(asOf: asOf, historyTransactions: historyTransactions)
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(.brand)
                    }
                }
            }

            if recentTransactions.isEmpty {
                // A card, not a button: it can stretch to fill the screen on
                // short displays and a glass capsule would turn into an egg.
                VStack(spacing: 12) {
                    Group {
                        if asOf != nil {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("No transactions by this time")
                                .font(.subheadline.weight(.medium))
                            Text("Move forward in history or return to Now.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isSyncing {
                            ProgressView()
                                .tint(.brand)
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
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .frame(minHeight: emptyStateMinHeight)
                .dashboardCard()
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
            .closesForPaymentLink()
            .presentationDetents([.fraction(0.75), .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// "As of now" while History shows the present, or the moment picked on
/// the chart. Its digits roll like the balance above while a finger scrubs.
struct ActivityAsOfText: View {
    let asOf: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        guard let asOf else {
            return String(localized: "As of now", comment: "Activity header while History shows the present")
        }
        return String(
            localized: "As of \(asOf.formatted(date: .abbreviated, time: .shortened))",
            comment: "Activity header: the list shows transactions up to this date and time"
        )
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: text)
    }
}

/// Liquid glass transaction card for home page
struct RecentTransactionCard: View {
    let transaction: MoneroTransaction
    let onTap: () -> Void
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.type == .incoming ? "Received" : "Sent")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        // Whole: next to a long amount, "Получено" broke with a
                        // hyphen; the amount column gives way instead.
                        .fixedSize()
                        .foregroundColor(.primary)

                    Text(formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                TransactionAmountColumn(transaction: transaction, amount: amount)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(14)
        }
        .glassButtonStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.type == .incoming ? String(localized: "Received") : String(localized: "Sent")) \(amount.spoken), \(formattedDate), \(transaction.displayStatusText)")
        .accessibilityHint("Shows transaction details")
        .accessibilityIdentifier("wallet.transaction.\(transaction.id)")
    }

    private var amount: TransactionAmountText {
        TransactionAmountText(
            transaction: transaction,
            fiatAtTime: fiatAtTime,
            fiatFirst: priceService.showFiatFirst,
            receivedOn: receivedOn
        )
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .brand
    }

    /// The subaddress name an incoming transaction arrived on, spoken by
    /// VoiceOver only; the row stays as it was on screen.
    private var receivedOn: String? {
        walletManager.receivedOnRowName(for: transaction)
    }

    /// What the amount was worth when the transaction happened, in the
    /// selected currency. Nil until price history has loaded.
    private var fiatAtTime: String? {
        priceHistoryService.fiatValue(xmr: transaction.amount, at: transaction.timestamp)
            .map { priceService.formatFiat($0) }
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
            // The greeting and the chip stay put whether the list is open or
            // not; only the content below swaps, and that is what shows the
            // open state.
            HStack(spacing: 0) {
                DynamicGreeting()
                Spacer(minLength: 12)
                WalletSwitcherButton(isExpanded: $showWalletManager)
                    .environmentObject(walletManager)
            }
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

            if walletManager.showsEmptyRestoreHint {
                RestoreHeightHintBanner(restoreHeight: walletManager.activeWallet?.restoreHeight ?? 0) {
                    walletManager.dismissEmptyRestoreHint()
                }
                .padding(.horizontal)
            }
        }
        .animation(.easeInOut, value: walletManager.syncState)
        .animation(.easeInOut, value: walletManager.showsEmptyRestoreHint)
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
    let priceService = PriceService()
    let priceHistoryService = PriceHistoryService(priceService: priceService)
    WalletView()
        .environmentObject(WalletManager())
        .environmentObject(priceService)
        .environmentObject(priceHistoryService)
}
