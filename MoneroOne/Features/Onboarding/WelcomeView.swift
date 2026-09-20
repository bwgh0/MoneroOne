import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showCreate = false
    @State private var showRestore = false
    @State private var showTrezor = false
    /// Short screens (iPhone Duo cover, SE, landscape) get the horizontal
    /// hero + compact button grid instead of the tall centered stack.
    @State private var isSquat = false

    var body: some View {
        NavigationStack {
            Group {
                if isSquat {
                    squatLayout
                } else {
                    tallLayout
                }
            }
            .readableColumn()
            .detectSquatScreen($isSquat)
            .navigationDestination(isPresented: $showCreate) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showRestore) {
                RestorePickerView()
            }
            .navigationDestination(isPresented: $showTrezor) {
                PairTrezorView(trezorManager: walletManager.trezorManager)
            }
        }
    }

    // MARK: - Tall phones: centered vertical stack

    private var tallLayout: some View {
        VStack(spacing: 32) {
            Spacer()

            AnimatedMoneroLogo(size: 240)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                title
                tagline
            }

            Spacer()

            VStack(spacing: 12) {
                createButton
                restoreButton
                trezorButton
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Short screens: horizontal hero, buttons in a 1+2 grid

    private var squatLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // Hero centered in the space above the buttons. Title one size
            // down from the tall layout so "Monero One" stays on one line
            // next to the logo in a 328pt column.
            HStack(alignment: .center, spacing: 20) {
                AnimatedMoneroLogo(size: 120)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monero One")
                        .font(.title)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome.title")
                    tagline
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 32)

            VStack(spacing: 12) {
                createButton
                HStack(spacing: 12) {
                    restoreButton
                    trezorButton
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Pieces

    private var title: some View {
        Text("Monero One")
            .font(.largeTitle)
            .fontWeight(.bold)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("welcome.title")
    }

    private var tagline: some View {
        Text("Simple. Private. Secure.")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }

    private func buttonLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var createButton: some View {
        Button {
            showCreate = true
        } label: {
            buttonLabel("Create New Wallet", systemImage: "plus.circle.fill")
                .foregroundStyle(Color.white)
        }
        .glassProminentButtonStyle()
        .tint(.orange)
        .accessibilityLabel("Create New Wallet")
        .accessibilityHint("Double tap to create a new Monero wallet")
        .accessibilityIdentifier("welcome.createButton")
    }

    private var restoreButton: some View {
        Button {
            showRestore = true
        } label: {
            buttonLabel("Restore Wallet", systemImage: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(Color.primary)
        }
        .glassButtonStyle()
        .accessibilityLabel("Restore Wallet")
        .accessibilityHint("Double tap to restore an existing wallet from a seed phrase or view key")
        .accessibilityIdentifier("welcome.restoreButton")
    }

    private var trezorButton: some View {
        Button {
            showTrezor = true
        } label: {
            buttonLabel("Connect Trezor", systemImage: "lock.shield.fill")
                .foregroundStyle(Color.primary)
        }
        .glassButtonStyle()
        .accessibilityLabel("Connect Trezor")
        .accessibilityHint("Double tap to pair a Trezor hardware wallet over Bluetooth")
        .accessibilityIdentifier("welcome.trezorButton")
    }
}

#Preview {
    WelcomeView()
        .environmentObject(WalletManager())
}
