import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var mnemonic: [String] = []
    @State private var showSeedPhrase = false
    @State private var confirmed = false
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .seedType
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var selectedSeedType: WalletManager.SeedType = .polyseed
    @FocusState private var focusedField: PINField?

    enum PINField {
        case pin
        case confirmPin
    }

    enum Step {
        case seedType
        case setPIN
        case showSeed
        case confirmSeed
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .seedType:
                seedTypeView
            case .setPIN:
                setPINView
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

            SecureField("Enter PIN (6+ digits)", text: $pin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .focused($focusedField, equals: .pin)
                .submitLabel(.next)
                .onSubmit {
                    if pin.count >= 6 {
                        focusedField = .confirmPin
                    }
                }

            SecureField("Confirm PIN", text: $confirmPin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .focused($focusedField, equals: .confirmPin)
                .submitLabel(.go)
                .onSubmit {
                    if canProceed {
                        step = .showSeed
                    }
                }

            Button {
                step = .showSeed
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
            focusedField = .pin
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
        pin.count >= 6 && pin == confirmPin
    }

    private func createWallet() {
        Task {
            do {
                // For new wallets, fetch current chain height so we skip scanning
                // (no transactions can exist before the wallet was created)
                let chainHeight = await fetchCurrentChainHeight()

                try walletManager.saveWallet(mnemonic: mnemonic, pin: pin, restoreHeight: chainHeight)
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
