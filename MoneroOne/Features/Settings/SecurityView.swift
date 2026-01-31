import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @AppStorage("preferredPINLength") private var preferredPINLength = 6
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
                    .tint(.orange)
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
                            .foregroundColor(.orange)
                        Text("Change PIN")
                    }
                }
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
        .alert("Enter PIN to Enable \(biometricName)", isPresented: $showPINPrompt) {
            SecureField("PIN", text: $pinForBiometrics)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                useBiometrics = false
                pinForBiometrics = ""
            }
            Button("Enable") {
                enableBiometrics()
            }
        } message: {
            if let error = pinError {
                Text(error)
            } else {
                Text("Enter your PIN to enable \(biometricName) unlock")
            }
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
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
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
        // Verify PIN is correct by trying to get seed
        do {
            guard let _ = try walletManager.getSeedPhrase(pin: pinForBiometrics) else {
                pinError = "Invalid PIN"
                useBiometrics = false
                pinForBiometrics = ""
                showPINPrompt = true
                return
            }

            // PIN is correct, save for biometrics
            try walletManager.enableBiometricUnlock(pin: pinForBiometrics)
            pinForBiometrics = ""
            pinError = nil
        } catch {
            pinError = "Invalid PIN"
            useBiometrics = false
            pinForBiometrics = ""
            showPINPrompt = true
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
    @State private var selectedPINLength = 6
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

            VStack(spacing: 8) {
                Text("New PIN Length")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    // 4 digits option
                    Button {
                        selectedPINLength = 4
                        newPIN = ""
                        confirmPIN = ""
                    } label: {
                        Text("4 Digits")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selectedPINLength == 4 ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground))
                            .foregroundColor(selectedPINLength == 4 ? .orange : .primary)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selectedPINLength == 4 ? Color.orange : Color.clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)

                    // 6 digits option
                    Button {
                        selectedPINLength = 6
                        newPIN = ""
                        confirmPIN = ""
                    } label: {
                        Text("6 Digits")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selectedPINLength == 6 ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground))
                            .foregroundColor(selectedPINLength == 6 ? .orange : .primary)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selectedPINLength == 6 ? Color.orange : Color.clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 280)
            }
            .padding(.vertical, 8)

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
                            .tint(canChange ? Color.orange : Color.gray)
                    } else {
                        Image(systemName: "lock.rotation")
                            .font(.callout.weight(.semibold))
                        Text("Change PIN")
                            .font(.callout.weight(.semibold))
                    }
                }
                .foregroundStyle(canChange ? Color.orange : Color.gray)
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
            selectedPINLength = preferredPINLength
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
            // Verify current PIN and get seed
            guard let seed = try walletManager.getSeedPhrase(pin: currentPIN) else {
                errorMessage = "Invalid current PIN"
                isChanging = false
                return
            }

            // Save wallet with new PIN
            try walletManager.saveWallet(mnemonic: seed, pin: newPIN)

            // Update biometric PIN if enabled
            if walletManager.hasBiometricPinStored {
                try walletManager.enableBiometricUnlock(pin: newPIN)
            }

            // Save new PIN length preference
            preferredPINLength = selectedPINLength

            dismiss()
        } catch {
            errorMessage = "Failed to change PIN"
        }

        isChanging = false
    }
}

#Preview {
    NavigationStack {
        SecurityView()
            .environmentObject(WalletManager())
    }
}
