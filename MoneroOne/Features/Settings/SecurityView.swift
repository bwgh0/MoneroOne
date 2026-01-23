import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
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
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorMessage: String?
    @State private var isChanging = false

    var body: some View {
        VStack(spacing: 24) {
            SecureField("Current PIN", text: $currentPIN)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            SecureField("New PIN (6+ digits)", text: $newPIN)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            SecureField("Confirm New PIN", text: $confirmPIN)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                changePIN()
            } label: {
                HStack {
                    if isChanging {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Change PIN")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canChange ? Color.orange : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(!canChange || isChanging)

            Spacer()
        }
        .padding()
        .navigationTitle("Change PIN")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canChange: Bool {
        currentPIN.count >= 6 && newPIN.count >= 6 && newPIN == confirmPIN
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
