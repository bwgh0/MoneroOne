import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Group {
            if !walletManager.hasWallet {
                WelcomeView()
            } else if !walletManager.isUnlocked {
                UnlockView()
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut, value: walletManager.hasWallet)
        .animation(.easeInOut, value: walletManager.isUnlocked)
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager())
}
