import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var biometricAuth = BiometricAuthManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("preferredPINLength") private var preferredPINLength = 6

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isUnlocking = false
    @State private var attempts = 0
    @State private var lastBiometricAttempt: Date?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Logo
            AnimatedMoneroLogo(size: 120)

            Text("Monero One")
                .font(.title)
                .fontWeight(.bold)

            // PIN Entry with dots
            VStack(spacing: 20) {
                PINEntryView(
                    pin: $pin,
                    length: preferredPINLength,
                    label: "Enter your PIN to unlock",
                    autoFocus: true,
                    onComplete: {
                        unlockWithPIN()
                    }
                )
                .disabled(isUnlocking)

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .transition(.opacity)
                }

                Button {
                    unlockWithPIN()
                } label: {
                    HStack(spacing: 8) {
                        if isUnlocking {
                            ProgressView()
                                .tint(pin.count >= 4 ? Color.orange : Color.gray)
                        } else {
                            Image(systemName: "lock.open.fill")
                                .font(.callout.weight(.semibold))
                            Text("Unlock")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .foregroundStyle(pin.count >= 4 ? Color.orange : Color.gray)
                    .frame(width: 200)
                    .padding(.vertical, 12)
                }
                .glassButtonStyle()
                .disabled(pin.count < 4 || isUnlocking)
            }

            // Biometric Button
            if biometricAuth.canUseBiometrics && walletManager.hasBiometricPinStored {
                Button {
                    unlockWithBiometrics()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: biometricAuth.biometricType.iconName)
                            .font(.system(size: 32))
                        Text("Use \(biometricAuth.biometricType.displayName)")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .glassButtonStyle()
                .disabled(isUnlocking)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            triggerBiometricsIfAvailable()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                triggerBiometricsIfAvailable()
            }
        }
    }

    private func triggerBiometricsIfAvailable() {
        // Debounce: don't retry within 2 seconds
        if let last = lastBiometricAttempt, Date().timeIntervalSince(last) < 2 {
            return
        }
        guard !isUnlocking else { return }

        if biometricAuth.canUseBiometrics && walletManager.hasBiometricPinStored {
            lastBiometricAttempt = Date()
            // Small delay to let the UI settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                unlockWithBiometrics()
            }
        }
        // autoFocus on PINEntryView handles keyboard focus
    }

    private func unlockWithPIN() {
        isUnlocking = true
        errorMessage = nil

        do {
            try walletManager.unlock(pin: pin)
            // Success - ContentView will show MainTabView
        } catch {
            attempts += 1
            errorMessage = "Invalid PIN"
            pin = ""

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }

        isUnlocking = false
    }

    private func unlockWithBiometrics() {
        isUnlocking = true
        errorMessage = nil

        // The keychain will prompt for Face ID/Touch ID automatically
        do {
            try walletManager.unlockWithBiometrics()
            // Success
        } catch {
            // Biometric failed or was cancelled - user can try PIN
            errorMessage = nil // Don't show error, just let them use PIN
        }

        isUnlocking = false
    }
}

#Preview {
    UnlockView()
        .environmentObject(WalletManager())
}
