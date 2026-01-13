import SwiftUI

struct BackupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var pin = ""
    @State private var isUnlocked = false
    @State private var seedPhrase: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            if isUnlocked {
                unlockedView
            } else {
                lockedView
            }
        }
        .padding()
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Enter PIN to view seed phrase")
                .font(.headline)

            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .padding(.horizontal)

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                unlockSeed()
            } label: {
                Text("Unlock")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(pin.count >= 6 ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(pin.count < 6)
            .padding(.horizontal)

            Spacer()
        }
    }

    private var unlockedView: some View {
        VStack(spacing: 24) {
            Text("Your Seed Phrase")
                .font(.headline)

            Text("Write this down and store it safely. Never share it with anyone.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SeedPhraseView(words: seedPhrase)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)

            Spacer()

            Text("Warning: Anyone with this phrase can access your funds!")
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func unlockSeed() {
        // In real implementation, decrypt seed from keychain
        do {
            if let seed = try KeychainStorage().getSeed(pin: pin) {
                seedPhrase = seed.split(separator: " ").map(String.init)
                isUnlocked = true
                errorMessage = nil
            } else {
                errorMessage = "Invalid PIN"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        BackupView()
            .environmentObject(WalletManager())
    }
}
