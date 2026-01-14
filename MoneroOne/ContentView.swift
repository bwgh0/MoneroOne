import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @State private var attemptedAutoUnlock = false

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
        .onAppear {
            // Auto-unlock with biometrics when "Never" is set
            if walletManager.hasWallet && !walletManager.isUnlocked && !attemptedAutoUnlock {
                attemptedAutoUnlock = true
                if autoLockMinutes == -1 && walletManager.hasBiometricPinStored {
                    try? walletManager.unlockWithBiometrics()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager())
}
