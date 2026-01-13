import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var walletManager: WalletManager
    @StateObject private var biometricAuth = BiometricAuthManager()

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isUnlocking = false
    @State private var attempts = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Icon
            Image(systemName: "shield.checkered")
                .font(.system(size: 60))
                .foregroundColor(.orange)

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

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button {
                    unlockWithPIN()
                } label: {
                    if isUnlocking {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Unlock")
                    }
                }
                .fontWeight(.semibold)
                .frame(width: 200)
                .padding()
                .background(pin.count >= 6 ? Color.orange : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(14)
                .disabled(pin.count < 6 || isUnlocking)
            }

            // Biometric Button
            if biometricAuth.canUseBiometrics && biometricAuth.isBiometricEnabled {
                Button {
                    unlockWithBiometrics()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: biometricAuth.biometricType.iconName)
                            .font(.system(size: 40))
                        Text("Use \(biometricAuth.biometricType.displayName)")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                }
                .disabled(isUnlocking)
            }

            Spacer()

            // Delete Wallet Option
            Button {
                // This should show a confirmation dialog
            } label: {
                Text("Forgot PIN?")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear {
            if biometricAuth.canUseBiometrics && biometricAuth.isBiometricEnabled {
                unlockWithBiometrics()
            }
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
        Task {
            let success = await biometricAuth.authenticate(reason: "Unlock your Monero wallet")

            if success {
                // For biometric unlock, we need the stored PIN
                // In a real app, we'd store the PIN securely in keychain with biometric protection
                // For now, we'll prompt for PIN after first biometric unlock
                if let storedPIN = getStoredPIN() {
                    do {
                        try walletManager.unlock(pin: storedPIN)
                    } catch {
                        errorMessage = "Biometric unlock failed. Please use PIN."
                    }
                }
            }
        }
    }

    // In production, this would retrieve the PIN from keychain with biometric protection
    private func getStoredPIN() -> String? {
        // This is a simplified implementation
        // Real implementation would use keychain with kSecAccessControlBiometryAny
        return nil
    }
}

#Preview {
    UnlockView()
        .environmentObject(WalletManager())
}
