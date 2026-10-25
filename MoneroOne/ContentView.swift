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
                // No wallet has its keys on this iPhone (device backup,
                // Quick Start): no PIN can unlock, so offer the restore.
                if walletManager.allWalletsNeedRestore {
                    NeedsRestoreView()
                } else {
                    UnlockView()
                }
            } else {
                MainTabView()
                    .id(walletManager.walletSessionId)
            }
        }
        .edgeBreathingRoom()
        .animation(.easeInOut, value: hasAcceptedDisclaimer)
        .animation(.easeInOut, value: walletManager.hasWallet)
        .animation(.easeInOut, value: walletManager.isUnlocked)
        .animation(.easeInOut, value: walletManager.allWalletsNeedRestore)
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager())
}
