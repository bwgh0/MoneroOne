import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var biometricAuth = BiometricAuthManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isUnlocking = false
    @State private var attempts = 0
    @State private var lastBiometricAttempt: Date?
    @FocusState private var isPinFocused: Bool

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Logo
            AnimatedMoneroLogo(size: 120)

            Text("Monero One")
                .font(.title)
                .fontWeight(.bold)

            Text("Enter your PIN to unlock")
                .foregroundColor(.secondary)

            // PIN Entry
            VStack(spacing: 16) {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .disabled(isUnlocking)
                    .focused($isPinFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        if pin.count >= 6 && !isUnlocking {
                            unlockWithPIN()
                        }
                    }
                    .onKeyPress(.return) {
                        if pin.count >= 6 && !isUnlocking {
                            unlockWithPIN()
                            return .handled
                        }
                        return .ignored
                    }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button {
                    unlockWithPIN()
                } label: {
                    HStack(spacing: 8) {
                        if isUnlocking {
                            ProgressView()
                                .tint(pin.count >= 6 ? Color.orange : Color.gray)
                        } else {
                            Image(systemName: "lock.open.fill")
                                .font(.callout.weight(.semibold))
                            Text("Unlock")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .foregroundStyle(pin.count >= 6 ? Color.orange : Color.gray)
                    .frame(width: 200)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.glass)
                .disabled(pin.count < 6 || isUnlocking)
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
                .buttonStyle(.glass)
                .disabled(isUnlocking)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            triggerBiometricsIfAvailable()
        }
        .onChange(of: scenePhase) { _, newPhase in
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
        } else {
            isPinFocused = true
        }
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
