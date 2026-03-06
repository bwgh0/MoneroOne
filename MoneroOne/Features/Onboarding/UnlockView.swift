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
    @State private var showForgotPINConfirmation = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Logo
            AnimatedMoneroLogo(size: 120)
                .accessibilityHidden(true)

            Text("Monero One")
                .font(.title)
                .fontWeight(.bold)
                .accessibilityLabel("Monero One")
                .accessibilityAddTraits(.isHeader)

            // PIN Entry with dots
            VStack(spacing: 20) {
                PINEntryView(
                    pin: $pin,
                    length: preferredPINLength,
                    label: "Enter your PIN to unlock",
                    autoFocus: true,
                    accessibilityID: "unlock.pinEntry",
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
                        .accessibilityLabel(error)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityIdentifier("unlock.errorMessage")
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
                .accessibilityLabel(isUnlocking ? "Unlocking" : "Unlock")
                .accessibilityHint("Double tap to unlock with your PIN")
                .accessibilityIdentifier("unlock.unlockButton")
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
                .accessibilityLabel("Unlock with \(biometricAuth.biometricType.displayName)")
                .accessibilityHint("Double tap to authenticate with \(biometricAuth.biometricType.displayName)")
                .disabled(isUnlocking)
            }

            // Forgot PIN option
            Button {
                showForgotPINConfirmation = true
            } label: {
                Text("Forgot PIN?")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Forgot PIN")
            .accessibilityHint("Double tap to reset your wallet and start over")
            .padding(.top, 16)

            Spacer()
        }
        .padding()
        .alert("Forgot Your PIN?", isPresented: $showForgotPINConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset App", role: .destructive) {
                walletManager.deleteWallet()
            }
        } message: {
            Text("This will delete all wallet data from this device. You can restore your wallet using your seed phrase.\n\nThis action cannot be undone.")
        }
        .onAppear {
            // If UserDefaults was reset (reinstall/TestFlight), recover PIN length from keychain
            if UserDefaults.standard.object(forKey: "preferredPINLength") == nil,
               let keychainLength = KeychainStorage().getPinLength() {
                preferredPINLength = keychainLength
            }
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

        Task {
            do {
                try await walletManager.unlock(pin: pin)
                // Success - ContentView will show MainTabView
            } catch {
                attempts += 1
                errorMessage = "Invalid PIN"
                pin = ""

                // Haptic feedback
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isUnlocking = false
        }
    }

    private func unlockWithBiometrics() {
        isUnlocking = true
        errorMessage = nil

        Task {
            do {
                try await walletManager.unlockWithBiometrics()
                // Success
            } catch {
                // Biometric failed or was cancelled - user can try PIN
                errorMessage = nil
            }
            isUnlocking = false
        }
    }
}

#Preview {
    UnlockView()
        .environmentObject(WalletManager())
}
