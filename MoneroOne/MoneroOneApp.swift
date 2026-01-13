import SwiftUI

@main
struct MoneroOneApp: App {
    @StateObject private var walletManager = WalletManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
        }
    }
}
