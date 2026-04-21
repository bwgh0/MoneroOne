import SwiftUI

/// Chooser shown after the user taps "Restore Wallet" — picks between
/// restoring from a seed phrase (signing wallet) and restoring from an
/// address + private view key (view-only wallet). Uses the same radio-card
/// visual language as "Choose Seed Format" for consistency.
struct RestorePickerView: View {
    enum Kind: Hashable {
        case seed
        case viewOnly
    }

    // Multi-wallet params — forwarded to whichever restore flow the user picks.
    var isAddingWallet: Bool = false
    var existingPin: String? = nil

    @EnvironmentObject var walletManager: WalletManager
    @State private var selection: Kind = .seed
    // Onboarding-only fallback: when presented from WelcomeView there's no
    // add-wallet NavigationStack to push into, so we use local flags. The
    // add-wallet case pushes via walletManager.addWalletPath instead, which
    // survives the view-tree tear-down iOS does when snapshotting for the
    // app switcher.
    @State private var navigateToSeed = false
    @State private var navigateToViewKey = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose Restore Method")
                .font(.headline)
                .padding(.top, 8)

            VStack(spacing: 12) {
                SelectableOptionCard(
                    id: Kind.seed,
                    selection: $selection,
                    title: "Seed Phrase",
                    subtitle: "16, 24, or 25 word mnemonic",
                    detail: "Full wallet — you can send and receive."
                )
                .accessibilityIdentifier("restorePicker.seedOption")

                SelectableOptionCard(
                    id: Kind.viewOnly,
                    selection: $selection,
                    title: "View Key",
                    subtitle: "Address + private view key",
                    detail: "Watch-only — balances and transactions, no sending."
                )
                .accessibilityIdentifier("restorePicker.viewKeyOption")
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                if isAddingWallet {
                    switch selection {
                    case .seed: walletManager.addWalletPath.append(.restoreSeed)
                    case .viewOnly: walletManager.addWalletPath.append(.restoreViewKey)
                    }
                } else {
                    switch selection {
                    case .seed: navigateToSeed = true
                    case .viewOnly: navigateToViewKey = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .accessibilityIdentifier("restorePicker.continueButton")
        }
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToSeed) {
            RestoreWalletView(
                isAddingWallet: isAddingWallet,
                existingPin: existingPin
            )
        }
        .navigationDestination(isPresented: $navigateToViewKey) {
            RestoreViewKeyView(
                isAddingWallet: isAddingWallet,
                existingPin: existingPin
            )
        }
    }
}

#Preview {
    NavigationStack {
        RestorePickerView()
    }
}
