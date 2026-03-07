import SwiftUI
import BackgroundTasks
import os.log

private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "App")

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager = WalletManager()
    @StateObject private var priceService = PriceService()
    @StateObject private var priceAlertService = PriceAlertService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @State private var backgroundTime: Date?

    static let priceCheckTaskId = "one.monero.MoneroOne.priceCheck"

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    init() {
        #if DEBUG
        // UI test state reset — clear all persisted data for a clean slate
        if CommandLine.arguments.contains("--uitesting") && CommandLine.arguments.contains("--reset-state") {
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
            }
            KeychainStorage().deleteAll()
        }
        #endif

        // Migrate keychain items to new accessibility level (fixes wallet loss after device lock)
        KeychainStorage().migrateKeychainAccessibilityIfNeeded()

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
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(priceService)
                .environmentObject(priceAlertService)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    TrustedLocationSyncManager.shared.configure(walletManager: walletManager)
                    priceService.priceAlertService = priceAlertService
                    schedulePriceCheck()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase: newPhase)
        }
    }

    private func handleScenePhaseChange(newPhase: ScenePhase) {
        switch newPhase {
        case .inactive:
            // Lock immediately when going inactive (before background)
            if walletManager.isUnlocked && autoLockMinutes == 0 {
                walletManager.lock()
            }
        case .background:
            if walletManager.isUnlocked && autoLockMinutes == 0 {
                // Lock immediately (backup in case inactive didn't trigger)
                walletManager.lock()
            } else if walletManager.isUnlocked && autoLockMinutes > 0 {
                // Store time for delayed lock check
                backgroundTime = Date()
            }
            // Schedule next price check when going to background
            schedulePriceCheck()
        case .active:
            // Check if we should lock based on time in background
            if walletManager.isUnlocked, let bgTime = backgroundTime, autoLockMinutes > 0 {
                let elapsed = Date().timeIntervalSince(bgTime)
                let lockAfterSeconds = Double(autoLockMinutes * 60)
                if elapsed >= lockAfterSeconds {
                    walletManager.lock()
                }
            }
            backgroundTime = nil

            // Trigger sync refresh when returning to foreground
            if walletManager.isUnlocked {
                logger.info("App became active, triggering refresh")
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
