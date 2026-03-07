import SwiftUI

struct WelcomeView: View {
    @State private var showCreate = false
    @State private var showRestore = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Animated Monero Logo
                AnimatedMoneroLogo(size: 240)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Monero One")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome.title")

                    Text("Simple. Private. Secure.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showCreate = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.callout.weight(.semibold))
                            Text("Create New Wallet")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Create New Wallet")
                    .accessibilityHint("Double tap to create a new Monero wallet")
                    .accessibilityIdentifier("welcome.createButton")

                    Button {
                        showRestore = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.callout.weight(.semibold))
                            Text("Restore Wallet")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Restore Wallet")
                    .accessibilityHint("Double tap to restore an existing wallet from a seed phrase")
                    .accessibilityIdentifier("welcome.restoreButton")
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
            .navigationDestination(isPresented: $showCreate) {
                CreateWalletView()
            }
            .navigationDestination(isPresented: $showRestore) {
                RestoreWalletView()
            }
        }
    }
}

#Preview {
    WelcomeView()
}
