import SwiftUI

struct BackupSeedView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var pin = ""
    @State private var seedPhrase: [String]?
    @State private var errorMessage: String?
    @State private var isVerifying = false
    @State private var showSeed = false
    @State private var showCopiedAlert = false
    @State private var clipboardClearTask: DispatchWorkItem?
    @FocusState private var isPinFocused: Bool

    private let clipboardClearDelay: TimeInterval = 60 // Clear clipboard after 60 seconds

    var body: some View {
        VStack(spacing: 24) {
            if seedPhrase == nil {
                // PIN verification
                pinVerificationView
            } else {
                // Seed display
                seedDisplayView
            }
        }
        .navigationTitle("Backup Seed")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pinVerificationView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Enter PIN to view seed phrase")
                .font(.headline)

            Text("Your seed phrase is the only way to recover your wallet. Never share it with anyone.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            SecureField("Enter PIN", text: $pin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .multilineTextAlignment(.center)
                .focused($isPinFocused)
                .submitLabel(.go)
                .onSubmit {
                    if pin.count >= 6 && !isVerifying {
                        verifySeedAccess()
                    }
                }
                .onKeyPress(.return) {
                    if pin.count >= 6 && !isVerifying {
                        verifySeedAccess()
                        return .handled
                    }
                    return .ignored
                }
                .onAppear {
                    isPinFocused = true
                }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                verifySeedAccess()
            } label: {
                if isVerifying {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("View Seed Phrase")
                }
            }
            .fontWeight(.semibold)
            .frame(maxWidth: 200)
            .padding()
            .background(pin.count >= 6 ? Color.orange : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(14)
            .disabled(pin.count < 6 || isVerifying)

            Spacer()
        }
        .padding()
    }

    private var seedDisplayView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Warning banner
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Write this down and store it safely. Never share it!")
                        .font(.subheadline)
                }
                .padding()
                .background(Color.yellow.opacity(0.2))
                .cornerRadius(12)

                // Seed phrase display
                if let words = seedPhrase {
                    VStack(spacing: 16) {
                        SeedPhraseView(words: words)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(16)

                        // Toggle visibility
                        Button {
                            showSeed.toggle()
                        } label: {
                            HStack {
                                Image(systemName: showSeed ? "eye.slash" : "eye")
                                Text(showSeed ? "Hide Words" : "Show Words")
                            }
                            .font(.subheadline)
                            .foregroundColor(.orange)
                        }
                    }
                    .blur(radius: showSeed ? 0 : 8)
                }

                // Copy button
                Button {
                    copyToClipboard()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy to Clipboard")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal)

                Text("Warning: Copying to clipboard may expose your seed to other apps. Clipboard will be cleared in 60 seconds.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
        .alert("Seed Copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your seed phrase has been copied. The clipboard will be automatically cleared in 60 seconds for security.")
        }
        .onDisappear {
            // Cancel any pending clipboard clear when view disappears
            clipboardClearTask?.cancel()
        }
    }

    private func verifySeedAccess() {
        isVerifying = true
        errorMessage = nil

        // Try to get seed with PIN
        do {
            if let phrase = try walletManager.getSeedPhrase(pin: pin) {
                seedPhrase = phrase
                showSeed = true
            } else {
                errorMessage = "Invalid PIN"
            }
        } catch {
            errorMessage = "Invalid PIN"
        }

        isVerifying = false
    }

    private func copyToClipboard() {
        guard let words = seedPhrase else { return }
        let phrase = words.joined(separator: " ")

        // Cancel any existing clear task
        clipboardClearTask?.cancel()

        // Copy to clipboard
        UIPasteboard.general.string = phrase

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Show alert
        showCopiedAlert = true

        // Schedule clipboard clear after delay
        let clearTask = DispatchWorkItem { [phrase] in
            // Only clear if clipboard still contains the seed phrase
            if UIPasteboard.general.string == phrase {
                UIPasteboard.general.string = ""
            }
        }
        clipboardClearTask = clearTask
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardClearDelay, execute: clearTask)
    }
}

#Preview {
    NavigationStack {
        BackupSeedView()
            .environmentObject(WalletManager())
    }
}
