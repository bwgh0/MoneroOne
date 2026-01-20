import SwiftUI

struct RestoreWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var seedInput = ""
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .enterSeed
    @State private var errorMessage: String?
    @State private var isRestoring = false
    @State private var walletCreationDate: Date = Date()
    @State private var useCreationDate = true
    @FocusState private var focusedField: PINField?

    enum PINField {
        case pin
        case confirmPin
    }

    enum Step {
        case enterSeed
        case creationDate
        case setPIN
        case restoring
    }

    // Monero testnet genesis: approximately April 2014
    private static let genesisDate = Date(timeIntervalSince1970: 1397818193)

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .enterSeed:
                enterSeedView
            case .creationDate:
                creationDateView
            case .setPIN:
                setPINView
            case .restoring:
                restoringView
            }
        }
        .padding()
        .navigationTitle("Restore Wallet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var enterSeedView: some View {
        VStack(spacing: 24) {
            Text("Enter your 24 or 25-word seed phrase")
                .font(.headline)

            TextEditor(text: $seedInput)
                .frame(height: 150)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Text("Separate words with spaces")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                validateAndProceed()
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValidSeedCount ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(!isValidSeedCount)

            Spacer()
        }
    }

    private var setPINView: some View {
        VStack(spacing: 24) {
            Text("Set a PIN to secure your wallet")
                .font(.headline)

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
                        step = .restoring
                        restoreWallet()
                    }
                }
                .onKeyPress(.return) {
                    if canProceed {
                        step = .restoring
                        restoreWallet()
                        return .handled
                    }
                    return .ignored
                }

            Button {
                step = .restoring
                restoreWallet()
            } label: {
                Text("Restore Wallet")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canProceed ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(!canProceed)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            focusedField = .pin
        }
    }

    private var restoringView: some View {
        VStack(spacing: 24) {
            Text("Restoring your wallet...")
                .font(.headline)

            ProgressView()
                .scaleEffect(1.5)

            Text("This may take a moment")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var seedWords: [String] {
        seedInput
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var isValidSeedCount: Bool {
        seedWords.count == 24 || seedWords.count == 25
    }

    private var canProceed: Bool {
        pin.count >= 6 && pin == confirmPin
    }

    private func validateAndProceed() {
        if isValidSeedCount {
            errorMessage = nil
            step = .creationDate
        } else {
            errorMessage = "Please enter 24 or 25 words"
        }
    }

    private var creationDateView: some View {
        VStack(spacing: 24) {
            Text("When did you create this wallet?")
                .font(.headline)

            Text("This helps speed up transaction scanning by skipping blocks before your wallet existed.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Toggle("Use wallet creation date", isOn: $useCreationDate)
                .padding(.horizontal)

            if useCreationDate {
                DatePicker(
                    "Creation date",
                    selection: $walletCreationDate,
                    in: Self.genesisDate...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)
            } else {
                Text("Will scan from the beginning (slower)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                step = .setPIN
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    /// Convert a date to approximate Monero block height
    /// Monero block time ≈ 2 minutes (120 seconds)
    private func blockHeightFromDate(_ date: Date) -> UInt64 {
        let secondsSinceGenesis = date.timeIntervalSince(Self.genesisDate)
        guard secondsSinceGenesis > 0 else { return 0 }
        let blocks = UInt64(secondsSinceGenesis / 120) // 2 min per block
        return blocks
    }

    var startHeight: UInt64? {
        guard useCreationDate else { return nil }
        return blockHeightFromDate(walletCreationDate)
    }

    private func restoreWallet() {
        Task {
            do {
                let restoreDate = useCreationDate ? walletCreationDate : nil
                try walletManager.restoreWallet(mnemonic: seedWords, pin: pin, restoreDate: restoreDate)
                try walletManager.unlock(pin: pin)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .enterSeed
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RestoreWalletView()
            .environmentObject(WalletManager())
    }
}
