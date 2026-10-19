import SwiftUI

/// Transfer's first step: From is the current wallet, To lists every other
/// wallet in switcher order. A tap on a To row goes on to Send's amount step
/// with that wallet's saved primary address.
struct TransferWalletList: View {
    @EnvironmentObject var walletManager: WalletManager
    /// The wallet and the address the transfer goes to.
    let onPick: (WalletInfo, String) -> Void

    private static let rowGap: CGFloat = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("From")
                if let from = walletManager.activeWallet {
                    fromRow(from)
                }

                sectionLabel("To")
                    .padding(.top, 24)
                VStack(spacing: Self.rowGap) {
                    ForEach(destinations) { wallet in
                        toRow(wallet)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle("Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
    }

    /// Every wallet but the current one, in the switcher's order.
    private var destinations: [WalletInfo] {
        walletManager.wallets.filter { $0.id != walletManager.activeWallet?.id }
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - From

    /// The current wallet, as the switcher shows it: the check and the
    /// orange ring. It is fixed, so a tap does nothing.
    private func fromRow(_ wallet: WalletInfo) -> some View {
        Button {} label: {
            WalletRowContent(wallet: wallet, balance: walletManager.displayBalance, address: walletManager.primaryAddress) {
                WalletRowCheck(isSelected: true)
            }
            .padding(16)
        }
        .glassButtonStyle()
        .overlay {
            WalletRowSurface.ring(.brand.opacity(0.7))
        }
        .allowsHitTesting(false)
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("From: \(WalletRow.spokenLabel(wallet: wallet, balance: walletManager.displayBalance, isActive: true))", comment: "VoiceOver: the wallet a transfer sends from"))
        .accessibilityIdentifier("transfer.from")
    }

    // MARK: - To

    private func state(of wallet: WalletInfo) -> TransferDestinationState {
        TransferDestinationState.of(
            savedAddress: WalletAddressMatch.savedAddress(
                of: wallet,
                activeWalletId: walletManager.activeWallet?.id,
                activePrimaryAddress: walletManager.primaryAddress
            ),
            needsRestore: walletManager.needsRestore(wallet.id),
            isValidAddress: walletManager.isValidAddress
        )
    }

    /// A wallet to send to. One with no saved address, or with its keys not
    /// on this iPhone, is dimmed and cannot be picked.
    private func toRow(_ wallet: WalletInfo) -> some View {
        let state = state(of: wallet)
        let isReady: Bool
        let address: String?
        switch state {
        case .ready(let saved):
            isReady = true
            address = saved
        case .needsOpen:
            isReady = false
            address = nil
        case .needsRestore:
            isReady = false
            address = wallet.cachedPrimaryAddress
        }
        return Button {
            guard case .ready(let saved) = state else { return }
            onPick(wallet, saved)
        } label: {
            WalletRowContent(
                wallet: wallet,
                needsRestore: state == .needsRestore,
                balance: wallet.cachedBalance,
                address: address,
                note: state == .needsOpen ? String(localized: "Open this wallet once to send to it", comment: "Transfer: a wallet with no saved address yet") : nil
            ) {
                EmptyView()
            }
            .opacity(isReady ? 1 : 0.45)
            .padding(16)
            .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .disabled(!isReady)
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(wallet, state: state))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isReady ? Text("Double tap to send to this wallet", comment: "VoiceOver: a Transfer destination") : Text(verbatim: ""))
        .accessibilityIdentifier(isReady ? "transfer.to" : "transfer.to.dimmed")
    }

    /// Name, balance and kind as the switcher reads them, then why a dimmed
    /// row cannot be picked.
    private func spokenLabel(_ wallet: WalletInfo, state: TransferDestinationState) -> String {
        let base = WalletRow.spokenLabel(wallet: wallet, balance: wallet.cachedBalance, isActive: false, needsRestore: state == .needsRestore)
        guard state == .needsOpen else { return base }
        return base + ", " + String(localized: "Open this wallet once to send to it", comment: "Transfer: a wallet with no saved address yet")
    }
}
