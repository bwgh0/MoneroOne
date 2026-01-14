import SwiftUI

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager = WalletManager()
    @StateObject private var priceService = PriceService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @State private var backgroundTime: Date?

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    init() {
        // Configure background sync manager after a brief delay to ensure walletManager is ready
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(priceService)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    BackgroundSyncManager.shared.configure(walletManager: walletManager)
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
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
}
