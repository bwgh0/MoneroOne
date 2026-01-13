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

    enum Step {
        case enterSeed
        case setPIN
        case restoring
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .enterSeed:
                enterSeedView
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
            Text("Enter your 25-word seed phrase")
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
                    .background(seedWords.count == 25 ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(seedWords.count != 25)

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

            SecureField("Confirm PIN", text: $confirmPin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

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

    private var canProceed: Bool {
        pin.count >= 6 && pin == confirmPin
    }

    private func validateAndProceed() {
        if seedWords.count == 25 {
            errorMessage = nil
            step = .setPIN
        } else {
            errorMessage = "Please enter exactly 25 words"
        }
    }

    private func restoreWallet() {
        Task {
            do {
                try walletManager.restoreWallet(mnemonic: seedWords, pin: pin)
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
