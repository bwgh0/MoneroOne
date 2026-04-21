import SwiftUI
import LocalAuthentication

/// Restore flow for a view-only wallet — user pastes a primary address and a
/// private view key. Mirrors `RestoreWalletView`'s shape so the two onboarding
/// branches feel identical: enter-keys → creation-date → set-PIN → name-wallet
/// → restoring. Biometrics can be enabled later from Settings; keeping it out
/// of the onboarding critical path keeps this screen's scope small.
struct RestoreViewKeyView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @AppStorage("preferredPINLength") private var preferredPINLength = 6

    // Multi-wallet parameters — presented from AddWalletView in an unlocked
    // session. Onboarding uses the defaults.
    var isAddingWallet: Bool = false
    var existingPin: String? = nil

    // @SceneStorage — iOS rebuilds the view tree when snapshotting for the
    // app switcher, which wipes plain @State and kicks the user back to the
    // first step with empty fields. SceneStorage is restored across the
    // rebuild so typed keys + the current step survive.
    @SceneStorage("restoreVK.addressInput") private var addressInput = ""
    @SceneStorage("restoreVK.viewKeyInput") private var viewKeyInput = ""
    @SceneStorage("restoreVK.walletName") private var walletName: String = ""
    @SceneStorage("restoreVK.walletEmoji") private var walletEmoji: String = "\u{1F441}"
    @State private var pin = ""
    @State private var confirmPin = ""
    @SceneStorage("restoreVK.step") private var step: Step = .enterKeys
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var isRestoring = false
    @SceneStorage("restoreVK.creationDate") private var walletCreationDateTS: Double = Date().timeIntervalSince1970
    @SceneStorage("restoreVK.useCreationDate") private var useCreationDate = true
    @State private var selectedPINLength = 6
    @FocusState private var focusedField: PINField?

    private var walletCreationDate: Date {
        Date(timeIntervalSince1970: walletCreationDateTS)
    }

    private var walletCreationDateBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: walletCreationDateTS) },
            set: { walletCreationDateTS = $0.timeIntervalSince1970 }
        )
    }

    private enum PINField { case pin, confirmPin }

    private enum Step: String {
        case enterKeys
        case creationDate
        case setPIN
        case nameWallet
        case restoring
    }

    /// Monero mainnet genesis timestamp (2014-04-18). Restore-from-date
    /// selector is clamped to this range.
    private static let genesisDate: Date = {
        var components = DateComponents()
        components.year = 2014
        components.month = 4
        components.day = 18
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }()

    private var trimmedAddress: String {
        addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedViewKey: String {
        viewKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isAddressValid: Bool {
        MoneroWallet.isValidAddress(trimmedAddress, networkType: walletManager.networkType)
    }

    private var isViewKeyValid: Bool {
        guard trimmedViewKey.count == 64 else { return false }
        return trimmedViewKey.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private var canContinueFromKeys: Bool { isAddressValid && isViewKeyValid }

    private var canProceedPIN: Bool {
        pin.count == selectedPINLength && pin == confirmPin
    }

    var body: some View {
        Group {
            switch step {
            case .enterKeys: enterKeysView
            case .creationDate: creationDateView
            case .setPIN: setPINView
            case .nameWallet: nameWalletView
            case .restoring: restoringView
            }
        }
        .navigationTitle("Restore View-Only")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Restore Failed", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Steps

    private var enterKeysView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enter the primary address and private view key of the wallet you want to watch. No seed is stored on this device — you won't be able to send.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                HStack {
                    Text("Primary Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        pasteAddress()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("restoreViewKey.pasteAddressButton")
                }
                TextField("4..." , text: $addressInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(3, reservesSpace: true)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .accessibilityIdentifier("restoreViewKey.addressField")

                if !addressInput.isEmpty && !isAddressValid {
                    Text("Address doesn't look valid for \(walletManager.networkType == .testnet ? "testnet" : "mainnet").")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Text("Private View Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        pasteViewKey()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("restoreViewKey.pasteViewKeyButton")
                }
                TextField("64 lowercase hex characters", text: $viewKeyInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(3, reservesSpace: true)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .accessibilityIdentifier("restoreViewKey.viewKeyField")

                if !viewKeyInput.isEmpty && !isViewKeyValid {
                    Text("View key must be 64 lowercase hex characters.")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button {
                    step = .creationDate
                } label: {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(canContinueFromKeys ? Color.orange : Color.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .glassButtonStyle()
                .disabled(!canContinueFromKeys)
                .padding(.top, 12)
                .accessibilityIdentifier("restoreViewKey.continueKeysButton")
            }
            .padding(.horizontal, 20)
        }
    }

    private var creationDateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 16)

            Text("When was the wallet created?")
                .font(.headline)

            Text("Setting an accurate date speeds up scanning. Leave off to scan from genesis (slower).")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Toggle("I know the creation date", isOn: $useCreationDate)
                .padding(.horizontal)

            if useCreationDate {
                DatePicker(
                    "Creation date",
                    selection: walletCreationDateBinding,
                    in: Self.genesisDate...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)
            } else {
                Text("Will scan from the beginning")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                if isAddingWallet, let existingPin {
                    pin = existingPin
                    step = .nameWallet
                } else {
                    step = .setPIN
                }
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

    private var setPINView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 16)

            Text("Set a PIN")
                .font(.title3.weight(.semibold))

            Text("Unlocks this wallet on this device. View-only wallets still require a PIN so nobody can open your watch list without it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            PINEntryFieldView(
                pin: $pin,
                length: selectedPINLength,
                label: "Enter PIN",
                field: PINField.pin,
                focusedField: $focusedField,
                accessibilityID: "restoreViewKey.pinEntry",
                onComplete: { focusedField = .confirmPin }
            )

            PINEntryFieldView(
                pin: $confirmPin,
                length: selectedPINLength,
                label: "Confirm PIN",
                field: PINField.confirmPin,
                focusedField: $focusedField,
                accessibilityID: "restoreViewKey.confirmPinEntry",
                onComplete: {
                    if canProceedPIN {
                        preferredPINLength = selectedPINLength
                        step = .nameWallet
                    }
                }
            )

            if pin.count == selectedPINLength && confirmPin.count == selectedPINLength && pin != confirmPin {
                Text("PINs don't match")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button {
                preferredPINLength = selectedPINLength
                step = .nameWallet
            } label: {
                Text("Continue")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(canProceedPIN ? Color.orange : Color.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .disabled(!canProceedPIN)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear { focusedField = .pin }
    }

    private var nameWalletView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 16)

            EmojiPickerCircle(emoji: $walletEmoji)
                .padding(.top, 8)
            Text("Tap to pick an emoji")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Wallet name", text: $walletName)
                .textInputAutocapitalization(.sentences)
                .font(.subheadline)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)

            Button {
                restore()
            } label: {
                Text("Restore Wallet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .padding(.horizontal)

            Spacer()
        }
    }

    private var restoringView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Restoring wallet…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func pasteAddress() {
        guard let clipboard = UIPasteboard.general.string else { return }
        addressInput = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func pasteViewKey() {
        guard let clipboard = UIPasteboard.general.string else { return }
        viewKeyInput = clipboard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func restore() {
        step = .restoring
        isRestoring = true

        Task {
            do {
                let restoreDate: Date? = useCreationDate ? walletCreationDate : nil
                let name = walletName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? WalletStore().nextWalletName(existing: walletManager.wallets)
                    : walletName.trimmingCharacters(in: .whitespaces)

                try await walletManager.restoreViewOnlyWallet(
                    name: name,
                    emoji: walletEmoji,
                    address: trimmedAddress,
                    viewKey: trimmedViewKey,
                    pin: pin,
                    restoreDate: restoreDate
                )

                if !isAddingWallet {
                    KeychainStorage().savePinLength(selectedPINLength)
                }

                try await walletManager.unlock(pin: pin)

                if isAddingWallet {
                    await MainActor.run { dismiss() }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                    step = .enterKeys
                    isRestoring = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RestoreViewKeyView()
            .environmentObject(WalletManager())
    }
}
