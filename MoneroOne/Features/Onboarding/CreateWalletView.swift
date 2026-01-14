import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var mnemonic: [String] = []
    @State private var showSeedPhrase = false
    @State private var confirmed = false
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .setPIN
    @FocusState private var focusedField: PINField?

    enum PINField {
        case pin
        case confirmPin
    }

    enum Step {
        case setPIN
        case showSeed
        case confirmSeed
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
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
        .onAppear {
            mnemonic = walletManager.generateNewWallet()
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
                .onKeyPress(.return) {
                    if pin.count >= 6 {
                        focusedField = .confirmPin
                        return .handled
                    }
                    return .ignored
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
                .onKeyPress(.return) {
                    if canProceed {
                        step = .showSeed
                        return .handled
                    }
                    return .ignored
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
            .buttonStyle(.glass)
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
            .buttonStyle(.glass)
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
                try walletManager.saveWallet(mnemonic: mnemonic, pin: pin)
                try walletManager.unlock(pin: pin)
            } catch {
                print("Error creating wallet: \(error)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(WalletManager())
    }
}
