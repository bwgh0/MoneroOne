import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @AppStorage("preferredPINLength") private var preferredPINLength = 6
    @AppStorage("requireAuthForSend") private var requireAuthForSend = true
    @State private var biometricsAvailable = false
    @State private var biometricType: LABiometryType = .none
    @State private var useBiometrics = false
    @State private var showPINPrompt = false
    @State private var pinForBiometrics = ""
    @State private var pinError: String?

    var body: some View {
        List {
            Section("Authentication") {
                if biometricsAvailable {
                    Toggle(isOn: $useBiometrics) {
                        HStack(spacing: 12) {
                            Image(systemName: biometricIcon)
                                .foregroundColor(.blue)
                            Text(biometricName)
                        }
                    }
                    .onChange(of: useBiometrics) { newValue in
                        if newValue {
                            showPINPrompt = true
                        } else {
                            walletManager.disableBiometricUnlock()
                        }
                    }
                }

                NavigationLink {
                    ChangePINView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.brand)
                        Text("Change PIN")
                    }
                }
            }

            Section {
                Toggle(isOn: $requireAuthForSend) {
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.brand)
                        Text("Confirm Sends")
                    }
                }
            } footer: {
                Text("Hardware wallets confirm on the device instead.")
            }

            Section("Auto-Lock") {
                Picker("Lock After", selection: $autoLockMinutes) {
                    Text("Immediately").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("Never").tag(-1)
                }
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            checkBiometrics()
            useBiometrics = walletManager.hasBiometricPinStored
        }
        .sheet(isPresented: $showPINPrompt, onDismiss: {
            if !walletManager.hasBiometricPinStored {
                useBiometrics = false
            }
            pinForBiometrics = ""
            pinError = nil
        }) {
            BiometricPINSheet(
                biometricName: biometricName,
                biometricIcon: biometricIcon,
                pinLength: preferredPINLength,
                pin: $pinForBiometrics,
                pinError: $pinError,
                onEnable: { enableBiometrics() },
                onCancel: {
                    useBiometrics = false
                    pinForBiometrics = ""
                    showPINPrompt = false
                }
            )
            .presentationDetents([.medium])
        }
    }

    private var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private var biometricName: String {
        switch biometricType {
        case .faceID: return String(localized: "Face ID")
        case .touchID: return String(localized: "Touch ID")
        default: return String(localized: "Biometrics")
        }
    }

    private func checkBiometrics() {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricsAvailable = true
            biometricType = context.biometryType
        }
    }

    private func enableBiometrics() {
        do {
            guard try walletManager.verifyPin(pinForBiometrics) else {
                pinError = String(localized: "Invalid PIN")
                pinForBiometrics = ""
                return
            }

            try walletManager.enableBiometricUnlock(pin: pinForBiometrics)
            pinForBiometrics = ""
            pinError = nil
            showPINPrompt = false
        } catch {
            pinError = String(localized: "Invalid PIN")
            pinForBiometrics = ""
        }
    }
}

struct ChangePINView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorMessage: String?
    @State private var isChanging = false
    /// New PINs are 6 digits. The current PIN keeps its stored length.
    private let selectedPINLength = 6
    @FocusState private var focusedField: Field?

    enum Field { case current, new, confirm }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            PINEntryFieldView(
                pin: $currentPIN,
                length: preferredPINLength,
                label: "Current PIN",
                field: Field.current,
                focusedField: $focusedField,
                onComplete: {
                    focusedField = .new
                }
            )

            PINEntryFieldView(
                pin: $newPIN,
                length: selectedPINLength,
                label: "New PIN",
                field: Field.new,
                focusedField: $focusedField,
                onComplete: {
                    focusedField = .confirm
                }
            )

            PINEntryFieldView(
                pin: $confirmPIN,
                length: selectedPINLength,
                label: "Confirm New PIN",
                field: Field.confirm,
                focusedField: $focusedField,
                onComplete: {
                    if canChange {
                        changePIN()
                    }
                }
            )

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                changePIN()
            } label: {
                HStack(spacing: 8) {
                    if isChanging {
                        ProgressView()
                            .tint(canChange ? Color.brand : Color.gray)
                    } else {
                        Image(systemName: "lock.rotation")
                            .font(.callout.weight(.semibold))
                        Text("Change PIN")
                            .font(.callout.weight(.semibold))
                    }
                }
                .foregroundStyle(canChange ? Color.brand : Color.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canChange || isChanging)
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .navigationTitle("Change PIN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            focusedField = .current
        }
    }

    private var canChange: Bool {
        currentPIN.count >= 4 && newPIN.count == selectedPINLength && newPIN == confirmPIN
    }

    private func changePIN() {
        isChanging = true
        errorMessage = nil

        do {
            // Re-encrypt all wallets with new PIN
            try walletManager.reencryptAllWallets(oldPin: currentPIN, newPin: newPIN)
            KeychainStorage().savePinLength(selectedPINLength)

            // Update biometric PIN if enabled
            if walletManager.hasBiometricPinStored {
                try walletManager.enableBiometricUnlock(pin: newPIN)
            }

            // Save new PIN length preference
            preferredPINLength = selectedPINLength

            dismiss()
        } catch {
            errorMessage = String(localized: "Failed to change PIN")
        }

        isChanging = false
    }
}

struct BiometricPINSheet: View {
    let biometricName: String
    let biometricIcon: String
    let pinLength: Int
    @Binding var pin: String
    @Binding var pinError: String?
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: biometricIcon)
                    .font(.system(size: 48))
                    .foregroundColor(.brand)

                Text("Enter PIN to Enable \(biometricName)")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                PINEntryView(
                    pin: $pin,
                    length: pinLength,
                    label: "Enter your PIN",
                    autoFocus: true,
                    onComplete: { onEnable() }
                )

                if let error = pinError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button {
                    onEnable()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: biometricIcon)
                            .font(.callout.weight(.semibold))
                        Text("Enable \(biometricName)")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(pin.count == pinLength ? Color.brand : Color.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .disabled(pin.count < pinLength)
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SecurityView()
            .environmentObject(WalletManager())
    }
}
