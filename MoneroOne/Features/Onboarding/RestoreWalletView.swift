import SwiftUI
import LocalAuthentication

/// Which wallets a phrase may restore when their keys are missing on this
/// iPhone (device backup, Quick Start).
enum NeedsRestoreTarget: Hashable {
    /// The restore screen: any wallet that needs restore.
    case any
    /// A switcher row: only this wallet.
    case wallet(UUID)
}

struct RestoreWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6

    // Multi-wallet parameters
    var isAddingWallet: Bool = false
    var existingPin: String? = nil
    /// Set: the phrase restores the keys of an existing wallet that needs
    /// restore. The wallet keeps its name, icon and restore height, so the
    /// creation date step is skipped.
    var needsRestoreTarget: NeedsRestoreTarget? = nil
    @State private var needsRestoreMatch: WalletManager.NeedsRestoreMatch?
    /// The phrase is being checked against the wallets that need restore.
    @State private var isMatching = false

    @State private var walletName: String = ""
    @State private var walletEmoji: String = "\u{1F4B0}"

    /// The typed seed words, in memory only; cleared when the flow ends.
    @State private var seedEntry = SeedEntryModel()
    /// The seed step's Continue stays at the bottom, behind the keyboard; the
    /// grid takes its room while the keyboard is up.
    @State private var keyboardShown = false
    @State private var seedContinueHeight: CGFloat = 0
    /// Between keyboard will-hide and did-hide: a status scroll asked for
    /// then runs again once Continue's room is back.
    @State private var keyboardHiding = false
    @State private var statusScrollAfterKeyboard = false
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var step: Step = .enterSeed
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var isRestoring = false
    /// The seed step's duplicate check is running (keychain reads).
    @State private var isCheckingSeed = false
    @State private var walletCreationDate: Date = Date()
    /// Off scans the whole chain. A date within the last 30 days asks for
    /// confirmation: accepting today put the restore height ~1,440 blocks
    /// below the tip, so sync "finished" in seconds with an empty history.
    @State private var useCreationDate = true
    @State private var showRecentDateConfirm = false

    /// New PINs are 6 digits. Existing 4-digit PINs still unlock: UnlockView
    /// reads the stored length.
    private let selectedPINLength = 6
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
        case enterSeed
        case creationDate
        case setPIN
        case biometricSetup
        case nameWallet
        case restoring
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
        case .faceID: return String(localized: "Face ID")
        case .touchID: return String(localized: "Touch ID")
        case .opticID: return String(localized: "Optic ID")
        @unknown default: return String(localized: "Biometrics")
        }
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
            case .biometricSetup:
                biometricSetupView
            case .nameWallet:
                nameWalletView
            case .restoring:
                restoringView
            }
        }
        .padding()
        .phoneColumn(maxWidth: step == .enterSeed ? Self.seedColumnWidth : 432)
        .overlay(alignment: .bottom) {
            if step == .enterSeed {
                seedContinueButton
            }
        }
        .navigationTitle("Restore Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            seedEntry.reset()
        }
        .alert("Error Restoring Wallet", isPresented: $showErrorAlert) {
            Button("OK") {
                step = .enterSeed
            }
        } message: {
            Text(errorMessage ?? String(localized: "An unknown error occurred. Please check your seed phrase and try again."))
        }
    }

    private static let seedTopID = "seedTop"

    /// The seed step is wider on wide screens (the Duo inner display), so the
    /// word grid gets 4 columns and shows most of a 25-word phrase at once.
    /// Phones are narrower than this; nothing changes there.
    private static let seedColumnWidth: CGFloat = 656

    /// Scrolls above a pinned Continue (`seedContinueButton`), like the date
    /// step, except that Continue does not ride up with the keyboard: the
    /// word grid gets that room. The seed input is `SeedPhraseEntryView`.
    private var enterSeedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Text("Enter your seed phrase")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .id(Self.seedTopID)

                    Text("16 words (Polyseed), 24 words (BIP39), or 25 words (Legacy)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    SeedPhraseEntryView(model: seedEntry)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // Continue's room under the content while the keyboard is down.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: keyboardShown ? 0 : seedContinueHeight)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardShown = true
                keyboardHiding = false
                statusScrollAfterKeyboard = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHiding = true
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardShown = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                keyboardHiding = false
                guard statusScrollAfterKeyboard else { return }
                statusScrollAfterKeyboard = false
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(SeedPhraseEntryView.statusID, anchor: .bottom)
                }
            }
            // Keep the focused cell above the keyboard and the suggestion bar.
            .onChange(of: seedEntry.focusedIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(index)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard let index = seedEntry.focusedIndex else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(index)
                }
            }
            // The status line sits under the grid: bring it up when it has
            // news. Clear goes back to the top.
            .onChange(of: seedEntry.scrollRequest) { _, request in
                guard let request else { return }
                // The keyboard is closing (last word, a valid phrase, a
                // paste): Continue's room comes back after this scroll.
                statusScrollAfterKeyboard = request.target == .status && keyboardHiding
                withAnimation(.easeOut(duration: 0.25)) {
                    switch request.target {
                    case .status:
                        proxy.scrollTo(SeedPhraseEntryView.statusID, anchor: .bottom)
                    case .top:
                        proxy.scrollTo(Self.seedTopID, anchor: .top)
                    }
                }
            }
        }
    }

    /// The seed step's Continue, pinned at the bottom of the screen. It
    /// ignores the keyboard, so it stays behind it while the person types;
    /// the keyboard closes by itself once the phrase is complete.
    private var seedContinueButton: some View {
        Button {
            validateAndProceed()
        } label: {
            HStack(spacing: 8) {
                if isMatching {
                    ProgressView()
                        .tint(Color.brand)
                } else {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
            }
            .foregroundStyle(seedEntry.isValid && !isCheckingSeed ? Color.brand : Color.gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .glassButtonStyle()
        .disabled(!seedEntry.isValid || isCheckingSeed || isMatching)
        .accessibilityLabel("Continue")
        .accessibilityHint(seedEntry.isValid ? "Double tap to proceed with your seed phrase" : "Enter a valid seed phrase to continue")
        .accessibilityIdentifier("restore.continueButton")
        .accessibilityHidden(keyboardShown)
        .padding(.top, 8)
        .background(Color(.systemBackground))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { seedContinueHeight = $0 }
        .padding([.horizontal, .bottom])
        .readableColumn(maxWidth: Self.seedColumnWidth)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var setPINView: some View {
        VStack(spacing: 24) {
            Text("Set a PIN to secure your wallet")
                .font(.headline)
                .multilineTextAlignment(.center)
                // Longer languages need two lines; with the keyboard up the
                // column is short and the prompt was cut to one ("…schüt…").
                .fixedSize(horizontal: false, vertical: true)

            // PIN Entry
            PINEntryFieldView(
                pin: $pin,
                length: selectedPINLength,
                label: "Enter PIN",
                field: PINField.pin,
                focusedField: $focusedField,
                accessibilityID: "restore.pinEntry",
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
                accessibilityID: "restore.confirmPinEntry",
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
                    .accessibilityLabel("PINs don't match")
                    .accessibilityIdentifier("restore.pinMismatchError")
            }

            Button {
                // Save the selected PIN length preference
                preferredPINLength = selectedPINLength
                proceedAfterPIN()
            } label: {
                HStack(spacing: 8) {
                    Text("Restore Wallet")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canProceed ? Color.brand : Color.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canProceed)
            .accessibilityLabel("Restore Wallet")
            .accessibilityHint(canProceed ? "Double tap to restore your wallet" : "Enter and confirm your PIN to continue")
            .accessibilityIdentifier("restore.pin.continueButton")
            .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            focusedField = .pin
        }
    }

    private var biometricSetupView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: biometricIcon)
                .font(.system(size: 80))
                .foregroundColor(.brand)
                .accessibilityHidden(true)

            Text("Enable \(biometricName)?")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

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
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .accessibilityLabel("Enable \(biometricName)")
                .accessibilityHint("Double tap to enable \(biometricName) for quick unlock")

                Button {
                    enableBiometrics = false
                    step = .nameWallet
                } label: {
                    Text("Skip for Now")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
                .accessibilityLabel("Skip for Now")
                .accessibilityHint("Double tap to skip biometric setup")
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    private var nameWalletView: some View {
        VStack(spacing: 24) {
            Spacer()

            EmojiPickerCircle(emoji: $walletEmoji, size: 80, fontSize: 44)

            TextField("Wallet name", text: $walletName)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 40)

            Text("You can change this later")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                // A second tap before the step changes must not start a
                // second restore.
                guard !isRestoring else { return }
                isRestoring = true
                step = .restoring
                restoreWallet()
            } label: {
                HStack(spacing: 8) {
                    Text("Restore Wallet")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .padding(.horizontal)
        }
        .onAppear {
            if walletName.isEmpty {
                walletName = WalletStore().nextWalletName(existing: walletManager.wallets)
            }
        }
    }

    private var restoringView: some View {
        VStack(spacing: 24) {
            Text("Restoring your wallet...")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ProgressView()
                .scaleEffect(1.5)
                .accessibilityLabel("Restoring wallet in progress")

            Text("This may take a moment")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    /// Check if the seed is a polyseed (16 words)
    private var isPolyseed: Bool {
        seedEntry.format == .polyseed
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
        if isAddingWallet {
            step = .nameWallet
            return
        }
        checkBiometrics()
        if biometricsAvailable {
            step = .biometricSetup
        } else {
            step = .nameWallet
        }
    }

    private func authenticateBiometrics() {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: String(localized: "Verify \(biometricName) to enable quick unlock", comment: "Face ID or Touch ID")
                )
                await MainActor.run {
                    if success {
                        enableBiometrics = true
                        step = .nameWallet
                    }
                }
            } catch {
                // User cancelled or biometrics failed - stay on this screen
                // They can try again or skip
            }
        }
    }

    private func validateAndProceed() {
        guard !isCheckingSeed, !isMatching else { return }

        // Commit the word being typed before reading the phrase.
        seedEntry.keyboard.dismiss()

        // Continue is enabled only for a valid phrase (wallet2 / Polyseed /
        // BIP39 checksum); these are the canonical list words.
        guard let words = seedEntry.validWords else { return }

        if let target = needsRestoreTarget {
            matchWalletNeedingRestore(target, words: words)
            return
        }

        // Check for duplicate wallet (only when PIN is available, i.e. adding
        // to existing wallets). The keychain reads run off the main actor;
        // Continue stays disabled until the check ends.
        guard isAddingWallet, let pin = existingPin else {
            proceedFromSeed()
            return
        }
        isCheckingSeed = true
        Task {
            defer { isCheckingSeed = false }
            let result: Error?
            do {
                try await walletManager.checkForDuplicateSeed(seedPhrase: words.joined(separator: " "), pin: pin)
                result = nil
            } catch {
                result = error
            }
            // The grid stays editable during the check: act only on the
            // phrase that was checked.
            guard step == .enterSeed, seedEntry.validWords == words else { return }
            if let result {
                seedEntry.showError(result.localizedDescription)
            } else {
                proceedFromSeed()
            }
        }
    }

    private func proceedFromSeed() {
        seedEntry.showError(nil)
        errorMessage = nil

        // All checks passed — proceed
        if isPolyseed {
            if isAddingWallet, let existingPin = existingPin {
                pin = existingPin
                step = .nameWallet
            } else {
                step = .setPIN
            }
        } else {
            step = .creationDate
        }
    }

    /// Checks that the phrase belongs to a wallet that needs restore, then
    /// prefills that wallet's name and icon. Its restore height carries
    /// over, so the creation date step is skipped.
    private func matchWalletNeedingRestore(_ target: NeedsRestoreTarget, words: [String]) {
        isMatching = true
        seedEntry.showError(nil)
        errorMessage = nil
        var walletId: UUID?
        if case .wallet(let id) = target { walletId = id }
        Task {
            defer { isMatching = false }
            do {
                let match = try await walletManager.matchWalletNeedingRestore(mnemonic: words, walletId: walletId)
                // The grid stays editable during the check: act only on the
                // phrase that was checked.
                guard step == .enterSeed, seedEntry.validWords == words else { return }
                if let wallet = walletManager.wallets.first(where: { $0.id == match.walletId }) {
                    walletName = wallet.name
                    walletEmoji = wallet.emoji
                }
                needsRestoreMatch = match
                if isAddingWallet, let existingPin {
                    pin = existingPin
                    step = .nameWallet
                } else {
                    step = .setPIN
                }
            } catch {
                guard step == .enterSeed, seedEntry.validWords == words else { return }
                seedEntry.showError(error.localizedDescription)
            }
        }
    }

    /// Scrolls so the graphical calendar never squeezes the copy on short
    /// screens (iPhone Duo inner display); Continue stays pinned below.
    private var creationDateView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("When did you create this wallet?")
                    .font(.headline)

                Text("This helps speed up transaction scanning by skipping blocks before your wallet existed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Toggle("Use wallet creation date", isOn: $useCreationDate)
                    .accessibilityLabel("Use wallet creation date")
                    .accessibilityHint("Toggle to specify when the wallet was created for faster scanning")
                    .accessibilityIdentifier("restore.date.toggle")
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
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button {
                proceedFromCreationDate()
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .accessibilityLabel("Continue")
            .accessibilityHint("Double tap to proceed to PIN setup")
            .accessibilityIdentifier("restore.date.continueButton")
            .padding(.horizontal)
            .alert("Restore from \(walletCreationDate.formatted(date: .abbreviated, time: .omitted))?", isPresented: $showRecentDateConfirm) {
                Button("Choose another date", role: .cancel) { }
                Button("Continue") { advanceFromCreationDate() }
            } message: {
                Text("Only finds transactions after this date.")
            }
            .padding(.top, 8)
            .background(Color(.systemBackground))
        }
    }

    /// A date inside the last 30 days is the classic mistake (the picker used
    /// to default to today), so confirm it before moving on.
    private func proceedFromCreationDate() {
        if useCreationDate, walletCreationDate > Date().addingTimeInterval(-30 * 86_400) {
            showRecentDateConfirm = true
        } else {
            advanceFromCreationDate()
        }
    }

    private func advanceFromCreationDate() {
        if isAddingWallet, let existingPin = existingPin {
            pin = existingPin
            step = .nameWallet
        } else {
            step = .setPIN
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
                let restoreDate: Date?
                if isPolyseed {
                    restoreDate = nil
                } else {
                    restoreDate = useCreationDate ? walletCreationDate : nil
                }

                let name = walletName.trimmingCharacters(in: .whitespaces).isEmpty ? WalletStore().nextWalletName(existing: walletManager.wallets) : walletName.trimmingCharacters(in: .whitespaces)
                let emoji = walletEmoji
                guard let words = seedEntry.validWords else { throw WalletError.invalidMnemonic }
                if let match = needsRestoreMatch {
                    try walletManager.restoreWalletNeedingRestore(match, mnemonic: words, pin: pin, name: name, emoji: emoji)
                } else {
                    try await walletManager.restoreWallet(name: name, emoji: emoji, mnemonic: words, pin: pin, restoreDate: restoreDate)
                }

                if !isAddingWallet {
                    KeychainStorage().savePinLength(selectedPINLength)
                }

                // Enable biometrics if user opted in (only for first wallet)
                if enableBiometrics && !isAddingWallet {
                    try walletManager.enableBiometricUnlock(pin: pin)
                }

                try await walletManager.unlock(pin: pin)

                if isAddingWallet {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
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
