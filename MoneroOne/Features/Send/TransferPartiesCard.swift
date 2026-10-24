import SwiftUI

/// The top of Transfer's amount step: From (the current wallet, fixed) over
/// To. With other wallets, To is a pull-down whose first item is This
/// Wallet; with none, To is fixed on This Wallet. Under the card, a footer
/// says what a send to This Wallet does.
struct TransferPartiesCard: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.colorScheme) private var colorScheme
    /// The chosen destination: the current wallet for This Wallet.
    let selected: WalletInfo?
    /// A choice from the To menu, with the address the send goes to.
    let onSelect: (WalletInfo, String) -> Void

    private var from: WalletInfo? { walletManager.activeWallet }

    /// Every wallet but the current one, in the switcher's order.
    private var others: [WalletInfo] {
        walletManager.wallets.filter { $0.id != walletManager.activeWallet?.id }
    }

    /// The wallet under To: the chosen one, or this one when it is the
    /// only wallet.
    private var shown: WalletInfo? {
        others.isEmpty ? from : selected
    }

    private var isThisWallet: Bool {
        shown != nil && shown?.id == from?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                if let from {
                    TransferPartyRow(label: String(localized: "From", comment: "Transfer review: the wallet that sends")) {
                        TransferPartyDisc.emoji(from.emoji)
                    } name: {
                        Text(from.name)
                    }
                }
                Divider().padding(.leading, 68)
                toRow
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if isThisWallet {
                Text("Sends XMR back to this wallet as a new payment. You can spend it again in about 20 minutes.", comment: "Transfer: the footer under From and To when the XMR goes back to the same wallet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isThisWallet)
    }

    // MARK: - To

    @ViewBuilder
    private var toRow: some View {
        if others.isEmpty {
            // One wallet: This Wallet is the only destination, so no menu.
            toLabel(showsChevrons: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("To", comment: "Transfer review: the wallet that receives"))
                .accessibilityValue(Text("This Wallet", comment: "Transfer: the current wallet as a destination"))
        } else {
            Menu {
                Section {
                    thisWalletItem
                }
                Section {
                    ForEach(others) { wallet in
                        otherWalletItem(wallet)
                    }
                }
            } label: {
                toLabel(showsChevrons: true)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel(Text("To", comment: "Transfer review: the wallet that receives"))
            .accessibilityValue(selectedName)
            .accessibilityIdentifier("transfer.to")
        }
    }

    private var selectedName: Text {
        guard let shown else { return Text("Choose a wallet", comment: "Transfer: To before a wallet is chosen") }
        return isThisWallet ? Text("This Wallet", comment: "Transfer: the current wallet as a destination") : Text(verbatim: shown.name)
    }

    private func toLabel(showsChevrons: Bool) -> some View {
        TransferPartyRow(label: String(localized: "To", comment: "Transfer review: the wallet that receives")) {
            if let shown {
                TransferPartyDisc.emoji(shown.emoji)
            } else {
                TransferPartyDisc.glyph
            }
        } name: {
            selectedName
                .foregroundStyle(shown == nil ? Color.brand : Color.primary)
        } trailing: {
            if showsChevrons {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Menu items

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

    @ViewBuilder
    private var thisWalletItem: some View {
        if let from {
            let state = state(of: from)
            Button {
                if case .ready(let address) = state { onSelect(from, address) }
            } label: {
                Label {
                    Text("This Wallet", comment: "Transfer: the current wallet as a destination")
                    Text("Sends XMR back to itself", comment: "Transfer menu: the subtitle of This Wallet")
                } icon: {
                    Image(uiImage: WalletMenuIcon.image(for: from, colorScheme: colorScheme))
                }
            }
            .disabled(!isReady(state))
        }
    }

    private func otherWalletItem(_ wallet: WalletInfo) -> some View {
        let state = state(of: wallet)
        return Button {
            if case .ready(let address) = state { onSelect(wallet, address) }
        } label: {
            Label {
                Text(verbatim: wallet.name)
                Text(subtitle(for: wallet, state: state))
            } icon: {
                Image(uiImage: WalletMenuIcon.image(for: wallet, colorScheme: colorScheme))
            }
        }
        .disabled(!isReady(state))
    }

    private func isReady(_ state: TransferDestinationState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// The balance (fiat in Fiat Mode), or why the wallet cannot be chosen.
    private func subtitle(for wallet: WalletInfo, state: TransferDestinationState) -> String {
        switch state {
        case .needsRestore:
            return String(localized: "Needs restore", comment: "Wallet switcher: the wallet's keys are not on this iPhone")
        case .needsOpen:
            return String(localized: "Open this wallet once to send to it", comment: "Transfer: a wallet with no saved address yet")
        case .ready:
            if priceService.showFiatFirst, let balance = wallet.cachedBalance, let fiat = priceService.formatFiatValue(balance) {
                return fiat
            }
            return "\(wallet.cachedBalance.map(XMRFormatter.format) ?? "—") XMR"
        }
    }
}

/// One row of the From/To card, laid out as Review's wallet rows: the
/// 40 pt disc, the caption label over the name, an optional trailing.
struct TransferPartyRow<Disc: View, Name: View, Trailing: View>: View {
    let label: String
    let disc: Disc
    let name: Name
    let trailing: Trailing

    init(label: String, @ViewBuilder disc: () -> Disc, @ViewBuilder name: () -> Name, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.disc = disc()
        self.name = name()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            disc
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                name
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }
}

/// The 40 pt circle of a From/To row, as on Review.
enum TransferPartyDisc {
    static func emoji(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: 22))
            .frame(width: 40, height: 40)
            .background(Circle().fill(.ultraThinMaterial))
            .clipShape(Circle())
    }

    /// No wallet chosen yet: a gray wallet glyph.
    static var glyph: some View {
        Image(systemName: "wallet.bifold")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.ultraThinMaterial))
            .clipShape(Circle())
    }
}

/// A wallet's emoji with its kind badge, drawn as one image for a menu item
/// (a menu shows an image, not a view).
@MainActor
enum WalletMenuIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(for wallet: WalletInfo, colorScheme: ColorScheme) -> UIImage {
        let kind = wallet.requiresHardwareSession ? "hw" : (wallet.isViewOnly ? "vo" : "")
        let key = wallet.emoji + "|" + kind + "|" + (colorScheme == .dark ? "d" : "l")
        if let cached = cache[key] { return cached }
        let content = Text(wallet.emoji)
            .font(.system(size: 22))
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                if wallet.requiresHardwareSession {
                    HardwareAvatarBadge().scaleEffect(0.7).offset(x: 3, y: 3)
                } else if wallet.isViewOnly {
                    ViewOnlyAvatarBadge().scaleEffect(0.7).offset(x: 3, y: 3)
                }
            }
            .padding(3)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = UITraitCollection.current.displayScale
        let image = renderer.uiImage ?? UIImage()
        cache[key] = image
        return image
    }
}
