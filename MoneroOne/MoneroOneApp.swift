import SwiftUI
import BackgroundTasks

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
        // Register background task for price checking
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.priceCheckTaskId,
            using: nil
        ) { task in
            Self.handlePriceCheck(task: task as! BGAppRefreshTask)
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
                    BackgroundSyncManager.shared.configure(walletManager: walletManager)
                    priceService.priceAlertService = priceAlertService
                    schedulePriceCheck()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase: newPhase)
        }
    }

    private func handleScenePhaseChange(newPhase: ScenePhase) {
        guard walletManager.isUnlocked else { return }
        guard autoLockMinutes != -1 else { return } // Never lock

        switch newPhase {
        case .inactive:
            // Lock immediately when going inactive (before background)
            if autoLockMinutes == 0 {
                walletManager.lock()
            }
        case .background:
            if autoLockMinutes == 0 {
                // Lock immediately (backup in case inactive didn't trigger)
                walletManager.lock()
            } else {
                // Store time for delayed lock check
                backgroundTime = Date()
            }
            // Schedule next price check when going to background
            schedulePriceCheck()
        case .active:
            // Check if we should lock based on time in background
            if let bgTime = backgroundTime, autoLockMinutes > 0 {
                let elapsed = Date().timeIntervalSince(bgTime)
                let lockAfterSeconds = Double(autoLockMinutes * 60)
                if elapsed >= lockAfterSeconds {
                    walletManager.lock()
                }
            }
            backgroundTime = nil
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
            print("Failed to schedule price check: \(error)")
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
