import SwiftUI

struct BackupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6
    @State private var pin = ""
    @State private var isUnlocked = false
    @State private var seedPhrase: [String] = []
    @State private var errorMessage: String?
    @State private var showCopiedFeedback = false
    @State private var showCopiedAlert = false
    @State private var clipboardClearTask: DispatchWorkItem?
    @State private var legacySeed: [String]?
    @State private var polyseedWords: [String]?
    @State private var selectedFormat = 0  // 0 = original, 1 = alternate
    /// Wallet this screen was opened for. Captured at `.onAppear` so a
    /// mid-session wallet switch can't redirect the seed read to another
    /// wallet — if the active wallet ID diverges from this, dismiss.
    @State private var boundWalletId: UUID?

    private let clipboardClearDelay: TimeInterval = 300 // Clear clipboard after 5 minutes

    private var alternateFormats: [(label: String, words: [String])] {
        var formats: [(String, [String])] = []
        if let poly = polyseedWords, poly != seedPhrase {
            formats.append(("Polyseed (\(poly.count) words)", poly))
        }
        if let legacy = legacySeed, legacy != seedPhrase {
            formats.append(("Legacy (\(legacy.count) words)", legacy))
        }
        return formats
    }

    private var displayedSeed: [String] {
        if selectedFormat > 0, selectedFormat <= alternateFormats.count {
            return alternateFormats[selectedFormat - 1].words
        }
        return seedPhrase
    }

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
        .task {
            if boundWalletId == nil {
                boundWalletId = walletManager.activeWallet?.id
            }
            if UserDefaults.standard.object(forKey: "preferredPINLength") == nil {
                let length = await Task.detached { KeychainStorage().getPinLength() }.value
                if let length { preferredPINLength = length }
            }
        }
        .onChange(of: walletManager.activeWallet?.id) { _, newId in
            // Active wallet switched out from under us — any seed we might
            // still show belongs to a different wallet than the one the
            // user opened this screen for. Dismiss before leaking it.
            if let bound = boundWalletId, bound != newId {
                dismiss()
            }
        }
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

            if !alternateFormats.isEmpty {
                Picker("Format", selection: $selectedFormat) {
                    Text("Original (\(seedPhrase.count) words)").tag(0)
                    ForEach(Array(alternateFormats.enumerated()), id: \.offset) { index, format in
                        Text(format.label).tag(index + 1)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text("\(displayedSeed.count) words")
                .font(.caption)
                .foregroundStyle(.secondary)

            SeedPhraseView(words: displayedSeed)
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
        let fullPhrase = displayedSeed.joined(separator: " ")

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
        guard let boundId = boundWalletId ?? walletManager.activeWallet?.id else {
            errorMessage = "No wallet"
            return
        }
        do {
            if let seed = try walletManager.getSeedPhrase(pin: pin, expectedWalletId: boundId) {
                seedPhrase = seed
                legacySeed = walletManager.getLegacySeed()
                polyseedWords = walletManager.getPolyseed()
                isUnlocked = true
                errorMessage = nil
            } else {
                errorMessage = "Invalid PIN"
            }
        } catch WalletError.walletMismatch {
            dismiss()
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
