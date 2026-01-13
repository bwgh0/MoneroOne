import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Group {
            if walletManager.hasWallet {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager())
}
