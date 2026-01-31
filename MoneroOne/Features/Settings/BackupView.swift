import SwiftUI

struct BackupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("preferredPINLength") private var preferredPINLength = 6
    @State private var pin = ""
    @State private var isUnlocked = false
    @State private var seedPhrase: [String] = []
    @State private var errorMessage: String?
    @State private var showCopiedFeedback = false
    @State private var showCopiedAlert = false
    @State private var clipboardClearTask: DispatchWorkItem?

    private let clipboardClearDelay: TimeInterval = 300 // Clear clipboard after 5 minutes

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

            PINEntryView(
                pin: $pin,
                length: preferredPINLength,
                label: "",
                autoFocus: true,
                onComplete: {
                    unlockSeed()
                }
            )

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
                    .background(pin.count >= preferredPINLength ? Color.orange : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(pin.count < preferredPINLength)
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

            Button {
                copyToClipboard()
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

            Text("Warning: Anyone with this phrase can access your funds! Clipboard clears in 5 min.")
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
        .alert("Seed Copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your seed phrase has been copied. The clipboard will be automatically cleared in 5 minutes for security.")
        }
        .onDisappear {
            clipboardClearTask?.cancel()
        }
    }

    private func copyToClipboard() {
        let fullPhrase = seedPhrase.joined(separator: " ")

        // Cancel any existing clear task
        clipboardClearTask?.cancel()

        // Copy to clipboard
        UIPasteboard.general.string = fullPhrase

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Show feedback
        showCopiedFeedback = true
        showCopiedAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedFeedback = false
        }

        // Schedule clipboard clear after delay
        let clearTask = DispatchWorkItem { [fullPhrase] in
            if UIPasteboard.general.string == fullPhrase {
                UIPasteboard.general.string = ""
            }
        }
        clipboardClearTask = clearTask
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardClearDelay, execute: clearTask)
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
