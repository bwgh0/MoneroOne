import SwiftUI
import BackgroundTasks
import UIKit
import os.log

private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "App")

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager: WalletManager
    @StateObject private var priceService: PriceService
    @StateObject private var priceHistoryService: PriceHistoryService
    @StateObject private var priceAlertService = PriceAlertService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @State private var backgroundTime: Date?
    private let isBalanceHistoryFixture: Bool

    static let priceCheckTaskId = "one.monero.MoneroOne.priceCheck"

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Explicitly opted-in UI verification data. No seed is generated,
        // no wallet is opened, and the fixture never runs on a phone.
        if CommandLine.arguments.contains("--uitesting") && CommandLine.arguments.contains("--balance-history-fixture") {
            let prices = BalanceHistoryFixturePrices()
            _walletManager = StateObject(wrappedValue: BalanceHistoryFixtureWallet())
            _priceService = StateObject(wrappedValue: prices)
            _priceHistoryService = StateObject(wrappedValue: PriceHistoryService(priceService: prices, cacheDirectory: nil))
            isBalanceHistoryFixture = true
            return
        }
        #endif

        _walletManager = StateObject(wrappedValue: WalletManager())
        isBalanceHistoryFixture = false
        // The history service prices by the currency the price service
        // selects, so both state objects share one PriceService instance.
        let priceService = PriceService()
        _priceService = StateObject(wrappedValue: priceService)
        _priceHistoryService = StateObject(wrappedValue: PriceHistoryService(priceService: priceService))

        #if DEBUG
        // UI test state reset — clear all persisted data for a clean slate
        if CommandLine.arguments.contains("--uitesting") && CommandLine.arguments.contains("--reset-state") {
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
            }
            KeychainStorage().deleteAll()
            WalletStore().deleteAll()
        }
        #endif

        // Migrate keychain items (fast no-op after first run — uses UserDefaults flags)
        KeychainStorage().migrateKeychainAccessibilityIfNeeded()
        KeychainStorage().migrateRateLimitIfNeeded()

        // Register background task for price checking
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.priceCheckTaskId,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handlePriceCheck(task: refreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isBalanceHistoryFixture {
                    MainTabView()
                        .edgeBreathingRoom()
                } else {
                    ContentView()
                }
            }
                .environmentObject(walletManager)
                .environmentObject(priceService)
                .environmentObject(priceHistoryService)
                .environmentObject(priceAlertService)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    guard !isBalanceHistoryFixture else { return }
                    TrustedLocationSyncManager.shared.configure(walletManager: walletManager)
                    priceService.priceAlertService = priceAlertService
                    // Defer all price network calls until a wallet exists.
                    // Avoids IP/connection leak on first launch before seed.
                    if walletManager.hasWallet {
                        priceService.startAutoRefresh()
                        priceHistoryService.startAutoRefresh()
                        schedulePriceCheck()
                    }
                }
                .onChange(of: walletManager.hasWallet) { hasWallet in
                    guard !isBalanceHistoryFixture else { return }
                    if hasWallet {
                        priceService.startAutoRefresh()
                        priceHistoryService.startAutoRefresh()
                        schedulePriceCheck()
                    }
                }
                // `monero:` links from Safari, Messages, the camera and
                // other apps. The dashboard opens Send once it is unlocked.
                .onOpenURL { url in
                    walletManager.openPaymentLink(url)
                }
                .alert(
                    "Can't Open Payment Link",
                    isPresented: Binding(
                        get: { walletManager.paymentLinkError != nil && !walletManager.isSendFlowPresented },
                        set: { if !$0 { walletManager.paymentLinkError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(walletManager.paymentLinkError ?? "")
                }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase: newPhase)
        }
    }

    private func handleScenePhaseChange(newPhase: ScenePhase) {
        guard !isBalanceHistoryFixture else { return }
        // Add-wallet sheet is a long-running user flow (typing a seed, pasting
        // an address + view key from a password manager). Locking mid-flow
        // unmounts MainTabView and destroys the sheet + any partially-entered
        // input. Suppress auto-lock while the sheet is up.
        let suppressLock = walletManager.addWalletSheetPresented
        switch newPhase {
        case .inactive:
            // Lock immediately when going inactive (before background)
            if walletManager.isUnlocked && autoLockMinutes == 0 && !suppressLock {
                walletManager.lock()
            }
        case .background:
            if walletManager.isUnlocked && autoLockMinutes == 0 && !suppressLock {
                // Lock immediately (backup in case inactive didn't trigger)
                walletManager.lock()
            } else if walletManager.isUnlocked && autoLockMinutes > 0 {
                // Store time for delayed lock check
                backgroundTime = Date()
                // Pause wallet2's refresh thread under a background-task
                // assertion so iOS doesn't suspend us mid-HTTP-fetch and
                // leave wallet2's asio state torn (which crashes when the
                // app resumes and the async op completes against freed
                // memory). Use `pauseSyncAsync` so the bg-task assertion
                // is held until wallet2 has actually stopped scanning,
                // not just until the dispatch was queued.
                let app = UIApplication.shared
                var taskId: UIBackgroundTaskIdentifier = .invalid
                taskId = app.beginBackgroundTask(withName: "PauseWalletSync") {
                    app.endBackgroundTask(taskId)
                    taskId = .invalid
                }
                Task {
                    await walletManager.pauseSyncAsync()
                    if taskId != .invalid {
                        app.endBackgroundTask(taskId)
                    }
                }
            }
            // Schedule next price check when going to background.
            // Skip if no wallet exists yet to avoid IP leak before seed.
            if walletManager.hasWallet {
                schedulePriceCheck()
            }
        case .active:
            // A chart left open across a long background is stale; the live
            // tip would draw one long straight segment out to "now".
            if walletManager.hasWallet {
                Task {
                    await priceService.refreshIfStale()
                    await priceHistoryService.refreshIfStale()
                }
            }
            // Check if we should lock based on time in background
            if walletManager.isUnlocked, let bgTime = backgroundTime, autoLockMinutes > 0 {
                let elapsed = Date().timeIntervalSince(bgTime)
                let lockAfterSeconds = Double(autoLockMinutes * 60)
                if elapsed >= lockAfterSeconds && !suppressLock {
                    walletManager.lock()
                }
            }
            backgroundTime = nil

            // Trigger sync refresh when returning to foreground
            if walletManager.isUnlocked {
                logger.info("App became active, resuming sync and triggering refresh")
                walletManager.resumeSync()
                Task {
                    await walletManager.refresh()
                }
            } else {
                logger.info("App became active but wallet is locked, skipping refresh")
            }
        @unknown default:
            break
        }
    }

    private func schedulePriceCheck() {
        let request = BGAppRefreshTaskRequest(identifier: Self.priceCheckTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule price check: \(error.localizedDescription)")
        }
    }

    static func handlePriceCheck(task: BGAppRefreshTask) {
        // Schedule next check
        let request = BGAppRefreshTaskRequest(identifier: priceCheckTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)

        // Perform price check
        Task {
            let priceService = await PriceService()
            let alertService = await PriceAlertService()

            await priceService.fetchPrice()

            if let price = await priceService.xmrPrice {
                let triggered = await alertService.checkAlerts(
                    currentPrice: price,
                    currency: priceService.selectedCurrency
                )
                for alert in triggered {
                    PriceAlertNotificationManager.shared.sendAlert(alert, currentPrice: price)
                }
            }

            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Synthetic, offline data used only with both explicit UI-test launch flags.
/// Keep this separate from wallet persistence and all production chart data.
@MainActor
private final class BalanceHistoryFixtureWallet: WalletManager {
    static let end = ISO8601DateFormatter().date(from: "2026-09-28T16:00:00Z")!
    static let address = "4" + String(repeating: "A", count: 94)

    override init() {
        super.init()
        let wallet = WalletInfo(
            id: UUID(uuidString: "AE86C999-BA9E-48A8-B932-C3F2577B5E50")!,
            name: "History Demo", emoji: "💰", source: .seed(.polyseed),
            createdAt: Self.end.addingTimeInterval(-7 * 86_400),
            restoreHeight: 0, syncResetCount: 0, userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: Self.address, cachedBalance: Decimal(string: "12.4826")
        )
        wallets = [wallet]
        activeWallet = wallet
        isUnlocked = true
        balance = Decimal(string: "12.4826")!
        unlockedBalance = balance
        address = Self.address
        primaryAddress = Self.address
        syncState = .synced
        connectionStage = .synced
        transactions = [
            event("history-received-latest", type: .incoming, amount: "0.5", hoursAgo: 6),
            event("history-sent-recent", type: .outgoing, amount: "0.12", hoursAgo: 30),
            event("history-received-middle", type: .incoming, amount: "1.25", hoursAgo: 78),
            event("history-sent-early", type: .outgoing, amount: "0.08", hoursAgo: 126),
            event("history-received-opening", type: .incoming, amount: "10.9326", hoursAgo: 150)
        ]
    }

    private func event(_ id: String, type: MoneroTransaction.TransactionType, amount: String, hoursAgo: Double) -> MoneroTransaction {
        MoneroTransaction(
            id: id, type: type, amount: Decimal(string: amount)!, fee: 0,
            address: Self.address, timestamp: Self.end.addingTimeInterval(-hoursAgo * 3_600),
            confirmations: 120, status: .confirmed, memo: nil, blockHeight: 3_600_000,
            subaddressIndex: type == .incoming ? 0 : nil
        )
    }

    override func balanceLedger() async -> BalanceLedger {
        BalanceLedger(balance: balance, transactions: transactions, countsPendingIncoming: false)
    }

    override func refresh() async {}
    override func resumeSync() {}
}

@MainActor
private final class BalanceHistoryFixturePrices: PriceService {
    private let samples: [PriceDataPoint] = (0...168).map { hour in
        PriceDataPoint(
            timestamp: BalanceHistoryFixtureWallet.end.addingTimeInterval(Double(hour - 168) * 3_600),
            price: 255 + Double(hour) * 0.12 + sin(Double(hour) / 7) * 3
        )
    }

    override init() {
        super.init()
        selectedCurrency = "usd"
        usdToSelectedRate = 1
        xmrPrice = samples.last?.price
        lastUpdated = BalanceHistoryFixtureWallet.end
        priceChange24h = 2.4
        showFiatFirst = false
    }

    /// 24H holds no transfers and 1Y has no data, so the card's height can
    /// be checked against a range without dots and an empty one.
    override func chartData(for range: String) -> [PriceDataPoint] {
        switch range {
        case "1D": return Array(samples.suffix(6))
        case "1Y": return []
        default: return samples
        }
    }
    override func selectChartRange(_ range: String) { currentChartRange = range }
    override func startAutoRefresh() {}
    override func refreshIfStale() async {}
    override func fetchPrice() async {}
    override func fetchChartData(range: String = "7D", force: Bool = false) async {}
}
#endif
