import SwiftUI

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager = WalletManager()
    @StateObject private var priceService = PriceService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(priceService)
        }
    }
}
