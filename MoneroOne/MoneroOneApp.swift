import SwiftUI

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager = WalletManager()
    @StateObject private var priceService = PriceService()

    init() {
        // Configure background sync manager after a brief delay to ensure walletManager is ready
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(priceService)
                .onAppear {
                    BackgroundSyncManager.shared.configure(walletManager: walletManager)
                }
        }
    }
}
