import SwiftUI

/// Shown in place of the PIN screen when no wallet on this iPhone has its
/// keys. A device backup or Quick Start brings the wallet list
/// (UserDefaults) but not the ThisDeviceOnly keychain items, so no PIN can
/// pass. A recovery phrase restores the keys into the existing wallet,
/// which keeps its name, icon and restore height; "Remove these wallets"
/// starts over.
struct NeedsRestoreView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showRestore = false
    @State private var showRemoveConfirmation = false
    /// Short screens (iPhone Duo cover, SE, landscape): smaller logo, tighter stack.
    @State private var isSquat = false

    private var wallets: [WalletInfo] { walletManager.wallets }

    /// A recovery phrase restores seed wallets only. View-only and hardware
    /// wallets are removed and added again.
    private var canRestoreWithPhrase: Bool {
        wallets.contains { !$0.isViewOnly }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: isSquat ? 20 : 28) {
                    AnimatedMoneroLogo(size: isSquat ? 88 : 120)
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text("Restore your wallets")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("needsRestore.title")

                        bodyText
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        ForEach(wallets) { wallet in
                            walletRow(wallet)
                        }
                    }
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                buttons
            }
            .readableColumn()
            .detectSquatScreen($isSquat)
            .navigationDestination(isPresented: $showRestore) {
                RestoreWalletView(needsRestoreTarget: .any)
            }
            .alert(
                Text(String(localized: "Remove \(wallets.count) wallets? This is permanent.", comment: "Confirm: remove every wallet from this iPhone")),
                isPresented: $showRemoveConfirmation
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Remove All", role: .destructive) {
                    walletManager.deleteAllWallets()
                }
            } message: {
                Text("You can restore them only with their seed phrases or keys.")
            }
        }
    }

    /// A device backup carries no wallet2 files. With files still here, the
    /// keys went missing on this iPhone (for example after a developer team
    /// transfer), so the text names no cause.
    private var bodyText: Text {
        if walletManager.needsRestoreWalletFilesRemain {
            return Text("Monero One cannot read the wallet keys on this iPhone, so it needs to restore them.")
        }
        return Text("This iPhone was set up from a device backup. Wallet keys stay on the old iPhone, so Monero One needs to restore them here.")
    }

    /// Same pieces as the switcher row (emoji circle, name, 8…8 address),
    /// without its controls: the list only names what needs restore.
    private func walletRow(_ wallet: WalletInfo) -> some View {
        HStack(spacing: 14) {
            Text(wallet.emoji)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    // Hardware first: `isViewOnly` is true for it too.
                    if wallet.requiresHardwareSession {
                        HardwareAvatarBadge().offset(x: 3, y: 3)
                    } else if wallet.isViewOnly {
                        ViewOnlyAvatarBadge().offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(wallet.name)
                    .font(.subheadline.weight(.semibold))
                if let address = wallet.cachedPrimaryAddress, !address.isEmpty {
                    Text(verbatim: ReceiveAddressLogic.shortAddress(address))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(for: wallet))
    }

    private func spokenLabel(for wallet: WalletInfo) -> String {
        var parts = [wallet.name]
        if wallet.requiresHardwareSession {
            parts.append(String(localized: "hardware wallet", comment: "VoiceOver: wallet kind after name and balance"))
        } else if wallet.isViewOnly {
            parts.append(String(localized: "view-only", comment: "VoiceOver: wallet kind after name and balance"))
        }
        return parts.joined(separator: ", ")
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            if canRestoreWithPhrase {
                Button {
                    showRestore = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.callout.weight(.semibold))
                        Text("Restore with recovery phrase")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .glassProminentButtonStyle()
                .tint(.brand)
                .accessibilityLabel("Restore with recovery phrase")
                .accessibilityHint("Double tap to enter the recovery phrase of one of these wallets")
                .accessibilityIdentifier("needsRestore.restoreButton")
            }

            Button {
                showRemoveConfirmation = true
            } label: {
                Text("Remove these wallets")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .glassButtonStyle()
            .accessibilityLabel("Remove these wallets")
            .accessibilityHint("Double tap to remove every wallet from this iPhone")
            .accessibilityIdentifier("needsRestore.removeButton")
        }
        .padding(.horizontal, isSquat ? 24 : 40)
        .padding(.top, 8)
        .padding(.bottom, isSquat ? 12 : 24)
        .background(Color(.systemBackground))
    }
}

/// The phrase restore for one switcher row marked "Needs restore", under
/// the PIN already in use. Same flow as Add Wallet's phrase restore; the
/// phrase must match this wallet.
struct NeedsRestoreCover: View {
    let walletId: UUID
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RestoreWalletView(
                isAddingWallet: true,
                existingPin: walletManager.currentPinForAddWallet,
                needsRestoreTarget: .wallet(walletId)
            )
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // Same auto-lock pause as Add Wallet: the user may leave the app to
        // copy the phrase from a password manager.
        .onAppear { walletManager.addWalletSheetPresented = true }
        .onDisappear { walletManager.addWalletSheetPresented = false }
    }
}

#Preview {
    NeedsRestoreView()
        .environmentObject(WalletManager())
}
