import SwiftUI
import LocalAuthentication

struct SecurityView: View {
    @AppStorage("useBiometrics") private var useBiometrics = false
    @AppStorage("autoLockMinutes") private var autoLockMinutes = 5
    @State private var biometricsAvailable = false
    @State private var biometricType: LABiometryType = .none

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
}

struct ChangePINView: View {
    @Environment(\.dismiss) var dismiss
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorMessage: String?

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
                Text("Change PIN")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canChange ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(!canChange)

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
        // In real implementation, verify current PIN and update
        dismiss()
    }
}

#Preview {
    NavigationStack {
        SecurityView()
    }
}
