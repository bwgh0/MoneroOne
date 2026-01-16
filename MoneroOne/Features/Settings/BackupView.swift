import SwiftUI

struct BackupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var pin = ""
    @State private var isUnlocked = false
    @State private var seedPhrase: [String] = []
    @State private var errorMessage: String?
    @State private var showCopiedFeedback = false
    @FocusState private var isPinFocused: Bool

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
                .focused($isPinFocused)

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
        .onAppear {
            isPinFocused = true
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

            Button {
                let fullPhrase = seedPhrase.joined(separator: " ")
                UIPasteboard.general.string = fullPhrase
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                showCopiedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showCopiedFeedback = false
                }
            } label: {
                HStack {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    Text(showCopiedFeedback ? "Copied!" : "Copy Seed Phrase")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .padding(.horizontal)

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
