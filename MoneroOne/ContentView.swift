import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false

    var body: some View {
        Group {
            if !hasAcceptedDisclaimer {
                DisclaimerView(hasAcceptedDisclaimer: $hasAcceptedDisclaimer)
            } else if !walletManager.hasWallet {
                WelcomeView()
            } else if !walletManager.isUnlocked {
                UnlockView()
            } else {
                MainTabView()
                    .id(walletManager.walletSessionId)
            }
        }
        .accessibilityIdentifier("contentView.root")
        .animation(.easeInOut, value: hasAcceptedDisclaimer)
        .animation(.easeInOut, value: walletManager.hasWallet)
        .animation(.easeInOut, value: walletManager.isUnlocked)
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager())
}
