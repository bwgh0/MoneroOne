import SwiftUI

struct AddWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                AnimatedWalletIcon(size: 120)

                Text("Add Wallet")
                    .font(.title2.weight(.semibold))

                Text("Create a new wallet or restore an existing one from your seed phrase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 12) {
                    NavigationLink {
                        CreateWalletView(
                            isAddingWallet: true,
                            existingPin: walletManager.currentPinForAddWallet
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.callout.weight(.semibold))
                            Text("Create New Wallet")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()

                    NavigationLink {
                        RestorePickerView(
                            isAddingWallet: true,
                            existingPin: walletManager.currentPinForAddWallet
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.callout.weight(.semibold))
                            Text("Restore Wallet")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
