import SwiftUI
import LocalAuthentication

struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6

    @State private var mnemonic: [String] = []
    @State private var showSeedPhrase = false
    @State private var confirmed = false
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .seedType
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var selectedSeedType: WalletManager.SeedType = .polyseed
    @State private var selectedPINLength = 6
    @FocusState private var focusedField: PINField?

    // Biometrics
    @State private var biometricsAvailable = false
    @State private var biometricType: LABiometryType = .none
    @State private var enableBiometrics = false

    enum PINField {
        case pin
        case confirmPin
    }

    enum Step {
        case seedType
        case setPIN
        case biometricSetup
        case showSeed
        case confirmSeed
    }

    private var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        @unknown default: return "lock.fill"
        }
    }

    private var biometricName: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometrics"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .seedType:
                seedTypeView
            case .setPIN:
                setPINView
            case .biometricSetup:
                biometricSetupView
            case .showSeed:
                showSeedView
            case .confirmSeed:
                confirmSeedView
            }
        }
        .padding()
        .navigationTitle("Create Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error Creating Wallet", isPresented: $showErrorAlert) {
            Button("Try Again") {
                step = .seedType
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred. Please try again.")
        }
    }

    private var seedTypeView: some View {
        VStack(spacing: 24) {
            Text("Choose Seed Format")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                // Polyseed option (recommended)
                Button {
                    selectedSeedType = .polyseed
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Polyseed")
                                    .font(.headline)
                                Text("Recommended")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            }
                            Text("16 words with embedded wallet birthday")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("Faster restoration, same security")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedSeedType == .polyseed ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedSeedType == .polyseed ? .orange : .gray)
                            .font(.title2)
                    }
                    .padding()
                    .background(selectedSeedType == .polyseed ? Color.orange.opacity(0.1) : Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                // Standard option
                Button {
                    selectedSeedType = .bip39
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Standard")
                                .font(.headline)
                            Text("24 words (BIP39 format)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("Compatible with more wallets")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: selectedSeedType == .bip39 ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedSeedType == .bip39 ? .orange : .gray)
                            .font(.title2)
                    }
                    .padding()
                    .background(selectedSeedType == .bip39 ? Color.orange.opacity(0.1) : Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }

            Button {
                mnemonic = walletManager.generateNewWallet(type: selectedSeedType)
                step = .setPIN
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .padding(.horizontal)

            Spacer()
        }
    }

    private var setPINView: some View {
        VStack(spacing: 24) {
            Text("Set a PIN to secure your wallet")
                .font(.headline)
                .multilineTextAlignment(.center)

            // PIN Length Selection
            VStack(spacing: 8) {
                Text("PIN Length")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    // 4 digits option
                    Button {
                        selectedPINLength = 4
                        pin = ""
                        confirmPin = ""
                        focusedField = .pin
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

                    // 6 digits option (recommended)
                    Button {
                        selectedPINLength = 6
                        pin = ""
                        confirmPin = ""
                        focusedField = .pin
                    } label: {
                        VStack(spacing: 4) {
                            Text("6 Digits")
                                .font(.subheadline.weight(.medium))
                            Text("Recommended")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
                .padding(.horizontal, 20)
            }

            // PIN Entry
            PINEntryFieldView(
                pin: $pin,
                length: selectedPINLength,
                label: "Enter PIN",
                field: PINField.pin,
                focusedField: $focusedField,
                onComplete: {
                    focusedField = .confirmPin
                }
            )

            PINEntryFieldView(
                pin: $confirmPin,
                length: selectedPINLength,
                label: "Confirm PIN",
                field: PINField.confirmPin,
                focusedField: $focusedField,
                onComplete: {
                    if canProceed {
                        // Save the selected PIN length preference
                        preferredPINLength = selectedPINLength
                        proceedAfterPIN()
                    }
                }
            )

            if pin.count == selectedPINLength && confirmPin.count == selectedPINLength && pin != confirmPin {
                Text("PINs don't match")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                // Save the selected PIN length preference
                preferredPINLength = selectedPINLength
                proceedAfterPIN()
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canProceed ? Color.orange : Color.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canProceed)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            // Always default to 6 digits (recommended) for new wallets
            focusedField = .pin
        }
    }

    private var biometricSetupView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: biometricIcon)
                .font(.system(size: 80))
                .foregroundColor(.orange)

            Text("Enable \(biometricName)?")
                .font(.title2.weight(.semibold))

            Text("Unlock your wallet quickly and securely with \(biometricName) instead of entering your PIN.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Button {
                    authenticateBiometrics()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: biometricIcon)
                            .font(.callout.weight(.semibold))
                        Text("Enable \(biometricName)")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()

                Button {
                    enableBiometrics = false
                    step = .showSeed
                } label: {
                    Text("Skip for Now")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    private var showSeedView: some View {
        VStack(spacing: 24) {
            Text("Write down your seed phrase")
                .font(.headline)

            Text("This is the ONLY way to recover your wallet. Store it safely offline.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SeedPhraseView(words: mnemonic)
                .padding()

            Toggle("I have written down my seed phrase", isOn: $confirmed)
                .padding(.horizontal)

            Button {
                step = .confirmSeed
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(confirmed ? Color.orange : Color.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!confirmed)
            .padding(.horizontal)
        }
    }

    private var confirmSeedView: some View {
        VStack(spacing: 24) {
            Text("Creating your wallet...")
                .font(.headline)

            ProgressView()
                .scaleEffect(1.5)

            Spacer()
        }
        .onAppear {
            createWallet()
        }
    }

    private var canProceed: Bool {
        pin.count == selectedPINLength && pin == confirmPin
    }

    private func checkBiometrics() {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricsAvailable = true
            biometricType = context.biometryType
        } else {
            biometricsAvailable = false
            biometricType = .none
        }
    }

    private func proceedAfterPIN() {
        checkBiometrics()
        if biometricsAvailable {
            step = .biometricSetup
        } else {
            step = .showSeed
        }
    }

    private func authenticateBiometrics() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Verify \(biometricName) to enable quick unlock"
                )
                await MainActor.run {
                    if success {
                        enableBiometrics = true
                        step = .showSeed
                    }
                }
            } catch {
                // User cancelled or biometrics failed - stay on this screen
                // They can try again or skip
            }
        }
    }

    private func createWallet() {
        Task {
            do {
                // For new wallets, fetch current chain height so we skip scanning
                // (no transactions can exist before the wallet was created)
                let chainHeight = await fetchCurrentChainHeight()

                try walletManager.saveWallet(mnemonic: mnemonic, pin: pin, restoreHeight: chainHeight)

                // Enable biometrics if user opted in
                if enableBiometrics {
                    try walletManager.enableBiometricUnlock(pin: pin)
                }

                try walletManager.unlock(pin: pin)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    /// Fetch current chain height from the LWS for instant sync of new wallets
    /// Only called in lite mode - privacy mode skips this optimization
    private func fetchCurrentChainHeight() async -> UInt64? {
        // Only use LWS if in lite mode
        guard walletManager.syncMode == .lite else {
            return nil
        }

        let client = LiteWalletServerClient(isTestnet: walletManager.isTestnet)
        do {
            let heightResponse = try await client.getBlockchainHeight()
            return heightResponse.height
        } catch {
            #if DEBUG
            print("Failed to fetch chain height: \(error)")
            #endif
            // Fall back to nil - wallet will scan from beginning
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(WalletManager())
    }
}
