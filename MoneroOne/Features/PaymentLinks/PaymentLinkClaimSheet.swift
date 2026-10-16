import SwiftUI

/// The sheet a claim link opens: checks the link, waits for it to unlock,
/// claims it to the active wallet or another one the user picks. For a link
/// this device sent, it says so and offers Reclaim instead.
struct PaymentLinkClaimSheet: View {
    let presentation: PaymentLinksCoordinator.Presentation

    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = EnvelopeStore.shared
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        presentation.kind == .own ? String(localized: "Your Payment Link") : String(localized: "Payment Link")
    }

    var body: some View {
        if let record = store.record(id: presentation.id, role: presentation.kind == .own ? .sent : .received) {
            EnvelopeSessionView(
                record: record,
                walletManager: walletManager,
                claimWhenReady: presentation.autoClaim && presentation.kind == .claim,
                title: title,
                onClose: { dismiss() }
            )
        } else {
            NavigationStack {
                PaymentLinkMessageView(
                    systemImage: "exclamationmark.circle.fill",
                    tint: .red,
                    title: String(localized: "This link is not complete.")
                )
                .claimSheetBar(title: title, onClose: { dismiss() })
            }
        }
    }
}

private extension View {
    /// The sheet's inline title and Close button.
    func claimSheetBar(title: String, onClose: @escaping () -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                        .accessibilityLabel("Close")
                }
            }
    }
}

/// Shared body of the claim sheet and a sent link's live check. The session
/// lives on the navigation stack, so pushing the wallet list keeps the
/// envelope open.
private struct EnvelopeSessionView: View {
    @StateObject private var session: EnvelopeSession
    let title: String
    let onClose: () -> Void

    init(record: EnvelopeRecord, walletManager: WalletManager, claimWhenReady: Bool = false, title: String, onClose: @escaping () -> Void) {
        let session = EnvelopeSession(record: record, walletManager: walletManager)
        session.claimWhenReady = claimWhenReady
        _session = StateObject(wrappedValue: session)
        self.title = title
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            EnvelopeSessionContent(session: session, onClose: onClose)
                .claimSheetBar(title: title, onClose: onClose)
        }
        .interactiveDismissDisabled(session.isSweeping)
        .task { await session.start() }
        .onDisappear { session.stop() }
    }
}

/// Hero, text and actions for one envelope session. Used by the claim
/// sheet and by the sent link detail.
struct EnvelopeSessionContent: View {
    @ObservedObject var session: EnvelopeSession
    var onClose: (() -> Void)?

    @State private var copiedHash = false
    @State private var showWalletList = false

    private var record: EnvelopeRecord { session.record }
    private var isOwn: Bool { record.role == .sent }
    /// Ours: the amount sent. Sent to us: what the claim delivers (the
    /// balance a check saw less the sweep fee), else the v1 link's amount.
    /// Nil for a v2 link not checked yet.
    private var hintAmount: Decimal? {
        (isOwn ? record.knownAmount : record.claimAmount).map(EnvelopeRuntime.xmr)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)

            hero
                .frame(height: 160)

            VStack(spacing: 12) {
                text
            }
            .padding(.horizontal)
            .animation(.easeOut(duration: 0.3), value: session.phase)

            Spacer()

            actions
                .padding(.horizontal)
                .padding(.bottom)
        }
        .padding()
        .navigationDestination(isPresented: $showWalletList) {
            ClaimWalletList(session: session, isOwn: isOwn)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        switch session.phase {
        case .idle, .checking, .waiting, .sweeping:
            GradientSpinner()
                .accessibilityHidden(true)
        case .ready:
            disc(systemImage: "envelope.open.fill", tint: .brand)
        case .done:
            SuccessCheckmarkView()
                .accessibilityHidden(true)
        case .noFunding:
            disc(systemImage: "tray", tint: .gray)
        case .alreadyClaimed, .reclaimed:
            disc(systemImage: "checkmark.seal.fill", tint: .gray)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }

    private func disc(systemImage: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.15))
                .frame(width: 120, height: 120)
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Text

    @ViewBuilder
    private var text: some View {
        if isOwn, !session.phase.isTerminalForOwn {
            Text("This is your own link")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        switch session.phase {
        case .idle, .checking:
            if !isOwn {
                Text("Checking the link…")
                    .font(.title2.weight(.semibold))
            }
            if let hintAmount {
                Text("~\(XMRFormatter.format(hintAmount)) XMR", comment: "Claim sheet: the link's amount from its last check, an estimate")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel(Text("About \(XMRFormatter.format(hintAmount)) XMR", comment: "VoiceOver: the link's estimated amount"))
            }
            if case .checking(let progress?) = session.phase, progress > 0, progress < 1 {
                Text("Scanning blocks: \(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

        case .waiting(let confirmations):
            if !isOwn {
                Text("On its way")
                    .font(.title2.weight(.semibold))
            }
            if let hintAmount {
                Text("~\(XMRFormatter.format(hintAmount)) XMR", comment: "Claim sheet: the link's amount from its last check, an estimate")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel(Text("About \(XMRFormatter.format(hintAmount)) XMR", comment: "VoiceOver: the link's estimated amount"))
            }
            Text("\(min(confirmations, EnvelopeLink.confirmationsToUnlock))/\(EnvelopeLink.confirmationsToUnlock) confirmations")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Ready in about \(max(1, EnvelopeStatusRules.minutesUntilReady(confirmations: confirmations))) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .ready(let unlocked):
            readyAmount(unlocked: unlocked)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if record.isExpired() {
                Text("Expired")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if !isOwn, let expiryDate = record.expiryDate {
                Text("Claim by \(expiryDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .sweeping:
            Text(isOwn ? "Taking the money back…" : "Claiming…")
                .font(.title2.weight(.semibold))

        case .done(let txid, let amount):
            Text(isOwn ? "Reclaimed" : "Claimed!")
                .font(.title.weight(.bold))
                .foregroundStyle(.green)
            if amount > 0 {
                Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(amount))) XMR")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            let wallet = record.walletName ?? session.destinationWalletName
            if !wallet.isEmpty {
                Text("On its way to \(wallet)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            hashPill(txid)

        case .noFunding:
            Text(isOwn ? "No money in this link yet." : "No money in this link yet.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("It checks again every few seconds while this screen is open.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .alreadyClaimed:
            Text(isOwn ? "Already claimed" : "This link was already claimed.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

        case .reclaimed:
            Text("This link was already claimed.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

        case .failed(let message):
            Text("Something went wrong")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func hashPill(_ txid: String) -> some View {
        Button {
            UIPasteboard.general.string = txid
            copiedHash = true
            HapticFeedback.shared.softTick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedHash = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copiedHash ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                Text(copiedHash ? "Copied!" : ReceiveAddressLogic.shortAddress(txid))
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(copiedHash ? .green : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .accessibilityLabel(copiedHash ? "Transaction ID copied" : "Copy transaction ID")
    }

    /// Sent to us: what the claim delivers, an estimate (the sweep fee is
    /// wallet2's estimate, no transaction is built). Ours, or with no net
    /// amount: the unlocked balance.
    @ViewBuilder
    private func readyAmount(unlocked: UInt64) -> some View {
        if !isOwn, let net = record.netAmount {
            let amount = XMRFormatter.format(EnvelopeRuntime.xmr(net))
            Text("~\(amount) XMR", comment: "Claim sheet: the link's amount from its last check, an estimate")
                .accessibilityLabel(Text("About \(amount) XMR", comment: "VoiceOver: the link's estimated amount"))
        } else {
            Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(unlocked))) XMR")
        }
    }

    // MARK: - Destination

    /// Where the money goes: the wallet switcher's row without the balance,
    /// under "Claim to". With two or more wallets a tap opens the list to
    /// choose another; with one it only shows where the money goes.
    private func destinationRow(_ destination: PaymentLinkClaimDestination) -> some View {
        let canChoose = session.destinations.count > 1
        let title = isOwn ? String(localized: "Reclaim to") : String(localized: "Claim to")
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .accessibilityHidden(true)

            Button {
                guard canChoose else { return }
                showWalletList = true
            } label: {
                WalletRowContent(wallet: destination.wallet, showsBalance: false, balance: nil, address: destination.address) {
                    if canChoose {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .allowsHitTesting(canChoose)
            .disabled(session.isSweeping)
            .accessibilityLabel(Self.spokenDestination(title: title, wallet: destination.wallet))
            .accessibilityValue(ReceiveAddressLogic.shortAddress(destination.address))
            .accessibilityHint(canChoose
                ? String(localized: "Opens the wallet list to choose where the money goes", comment: "VoiceOver: hint on the claim sheet's wallet row")
                : "")
            .accessibilityRemoveTraits(canChoose ? [] : .isButton)
        }
    }

    /// "Claim to, Savings, view-only".
    static func spokenDestination(title: String, wallet: WalletInfo) -> String {
        var parts = [title, wallet.name]
        if wallet.requiresHardwareSession {
            parts.append(String(localized: "hardware wallet", comment: "VoiceOver: wallet kind after name and balance"))
        } else if wallet.isViewOnly {
            parts.append(String(localized: "view-only", comment: "VoiceOver: wallet kind after name and balance"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch session.phase {
            case .ready:
                if let destination = session.destination {
                    destinationRow(destination)
                        .padding(.bottom, 4)
                }
                Button {
                    HapticFeedback.shared.sendInitiated()
                    Task { await session.sweep() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOwn ? "arrow.uturn.backward" : "arrow.down.left")
                        Text(isOwn ? "Reclaim" : "Claim")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .accessibilityLabel(isOwn ? "Reclaim the money" : "Claim the money")
                .accessibilityHint(isOwn
                    ? "Moves the money in this link back to \(session.destinationWalletName)"
                    : "Moves the money in this link to \(session.destinationWalletName)")

            case .failed:
                Button {
                    Task { await session.start() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .accessibilityLabel("Retry")

            case .done:
                if let onClose {
                    Button(action: onClose) {
                        Text("Done")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Done")
                }

            default:
                EmptyView()
            }
        }
    }
}

private extension EnvelopeSession.Phase {
    /// Phases where the own-link headline would repeat the result.
    var isTerminalForOwn: Bool {
        switch self {
        case .done, .alreadyClaimed, .reclaimed, .failed, .sweeping: return true
        default: return false
        }
    }
}

/// The wallets a claim can go to, as the wallet switcher shows them: same
/// rows, same order, the chosen one with the check and the orange ring. No
/// rename or reorder here. A tap picks the wallet and goes back.
private struct ClaimWalletList: View {
    @ObservedObject var session: EnvelopeSession
    let isOwn: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(session.destinations) { destination in
                    row(destination)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle(isOwn ? String(localized: "Reclaim to") : String(localized: "Claim to"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ destination: PaymentLinkClaimDestination) -> some View {
        let isChosen = destination.walletId == session.destinationId
        return Button {
            session.destinationId = destination.walletId
            dismiss()
        } label: {
            WalletRowContent(wallet: destination.wallet, balance: destination.balance, address: destination.address) {
                WalletRowCheck(isSelected: isChosen)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .overlay {
            WalletRowSurface.ring(.brand.opacity(isChosen ? 0.7 : 0))
        }
        .opacity(isChosen ? 1 : 0.85)
        .disabled(session.isSweeping)
        // As the switcher reads its rows: name, balance, kind; the address
        // waits on the More Content rotor.
        .accessibilityLabel(WalletRow.spokenLabel(wallet: destination.wallet, balance: destination.balance, isActive: destination.isOpen))
        .accessibilityCustomContent(AccessibilityCustomContentKey("Address"), Text(destination.address))
        .accessibilityCustomContent("Icon", destination.wallet.emoji)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .padding(.horizontal)
    }
}

/// A centered glyph and one line, for states with nothing else to show.
struct PaymentLinkMessageView: View {
    let systemImage: String
    let tint: Color
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}
