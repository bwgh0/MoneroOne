import SwiftUI

// MARK: - Open links

/// Payment links that still hold money: links this wallet sent that nobody
/// claimed or reclaimed yet (waiting, ready or expired), and links sent to
/// this device that wait to be claimed here. The balance card sums them in
/// one or two lines; Activity's Links filter lists them under "Open Links".
/// Android ports the same rules.
enum OpenPaymentLinks {
    /// Where an open link stands, most urgent first: the Open Links group
    /// lists them in this order.
    enum Kind: Int, Comparable {
        /// Sent to us, waiting to be claimed here.
        case toClaim
        /// Ours, past its expiry: the money should come back.
        case expired
        /// Ours, not unlocked yet.
        case waiting
        /// Ours, unlocked: anyone with the link can claim it now.
        case ready

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Item: Identifiable {
        let record: EnvelopeRecord
        let kind: Kind
        var id: String { "\(record.role.rawValue).\(record.id)" }
    }

    /// What the balance card's lines say.
    struct Summary: Equatable {
        var sentCount = 0
        var expiredCount = 0
        /// Piconero in the open sent links: each link's amount, as its
        /// detail shows it.
        var sentAmount: UInt64 = 0
        var toClaimCount = 0
        /// Piconero the waiting claims deliver (`EnvelopeRecord.claimAmount`);
        /// nil while a link's amount is not known yet (a v2 link before its
        /// first check).
        var toClaimAmount: UInt64? = 0

        var isEmpty: Bool { sentCount == 0 && toClaimCount == 0 }
    }

    /// A link this wallet funded that nobody claimed or reclaimed: pending or
    /// ready, expired or not. A link funded from another wallet is that
    /// wallet's money; a record from before wallet ids counts in every wallet.
    static func isOpenSent(_ record: EnvelopeRecord, activeWalletId: String?) -> Bool {
        guard record.role == .sent, record.status == .pending || record.status == .ready else { return false }
        if let walletId = record.walletId, walletId != activeWalletId { return false }
        return true
    }

    /// A received link this device can still claim: not settled, and it
    /// still has the secret.
    static func isWaitingToClaim(_ record: EnvelopeRecord) -> Bool {
        record.role == .received && !record.status.isSettled && record.link != nil
    }

    static func summary(of records: [EnvelopeRecord], activeWalletId: String?, now: Date = Date()) -> Summary {
        var summary = Summary()
        for record in records {
            if isOpenSent(record, activeWalletId: activeWalletId) {
                summary.sentCount += 1
                summary.sentAmount += record.amount
                if record.isExpired(now: now) { summary.expiredCount += 1 }
            } else if isWaitingToClaim(record) {
                summary.toClaimCount += 1
                if let amount = record.claimAmount, let total = summary.toClaimAmount {
                    summary.toClaimAmount = total + amount
                } else {
                    summary.toClaimAmount = nil
                }
            }
        }
        return summary
    }

    /// `status`, `isExpired` and `confirmations` are the live ones
    /// (`PaymentLinkDisplay`).
    static func kind(role: EnvelopeRecord.Role, status: EnvelopeStatus, isExpired: Bool, confirmations: Int?) -> Kind {
        if role == .received { return .toClaim }
        if isExpired { return .expired }
        if status == .ready || (confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock { return .ready }
        return .waiting
    }

    /// Most urgent first, newest first within a kind.
    static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { lhs, rhs in
            lhs.kind != rhs.kind ? lhs.kind < rhs.kind : lhs.record.createdAt > rhs.record.createdAt
        }
    }

    /// The Open Links group, in order.
    @MainActor
    static func items(in store: EnvelopeStore, walletManager: WalletManager, now: Date = Date()) -> [Item] {
        let activeId = walletManager.activeWallet?.id.uuidString
        let items = store.records.compactMap { record -> Item? in
            if isWaitingToClaim(record) { return Item(record: record, kind: .toClaim) }
            guard isOpenSent(record, activeWalletId: activeId) else { return nil }
            let display = PaymentLinkDisplay(record: record, walletManager: walletManager, now: now)
            return Item(record: record, kind: kind(role: .sent, status: display.status, isExpired: display.isExpired, confirmations: display.confirmations))
        }
        return ordered(items)
    }

    // MARK: Text

    static func amountText(_ piconero: UInt64) -> String {
        "\(XMRFormatter.format(EnvelopeRuntime.xmr(piconero))) XMR"
    }

    /// "2 open links", "1 open link".
    static func openLinksText(count: Int) -> String {
        String(localized: "\(count) open links", comment: "Balance card: payment links you sent that nobody claimed yet")
    }

    /// "1 expired".
    static func expiredText(count: Int) -> String {
        String(localized: "\(count) expired", comment: "Balance card: how many of your open payment links expired")
    }

    /// "0.15 XMR in 2 open links".
    static func sentText(amount: UInt64, count: Int) -> String {
        String(localized: "\(amountText(amount)) in \(openLinksText(count: count))", comment: "Balance card: the money in your open payment links, then how many links")
    }

    /// The sent line as it reads: "0.15 XMR in 2 open links · 1 expired".
    static func sentLineText(amount: UInt64, count: Int, expired: Int) -> String {
        let text = sentText(amount: amount, count: count)
        guard expired > 0 else { return text }
        return String(localized: "\(text) · \(expiredText(count: expired))", comment: "Balance card: the open links line, then how many of them expired")
    }

    /// VoiceOver: "0.15 XMR in 2 open links, 1 expired".
    static func sentAccessibilityLabel(amount: UInt64, count: Int, expired: Int) -> String {
        let text = sentText(amount: amount, count: count)
        guard expired > 0 else { return text }
        return [text, expiredText(count: expired)].joined(separator: ", ")
    }

    /// "0.03 XMR to claim"; "2 links to claim" while an amount is not known.
    static func claimLineText(amount: UInt64?, count: Int) -> String {
        if let amount {
            return String(localized: "\(amountText(amount)) to claim", comment: "Balance card: money in payment links sent to you, waiting to be claimed")
        }
        return String(localized: "\(count) links to claim", comment: "Balance card: payment links sent to you, amount not known yet")
    }
}

// MARK: - Balance card lines

/// The balance card's open-link lines, under the balance: the money in
/// links this wallet sent that nobody claimed yet, and the money in links
/// sent to this device waiting to be claimed. A tap opens Activity's Links
/// filter; Claim claims the one link waiting, or opens the filter when
/// there are more.
struct OpenPaymentLinkLines: View {
    let summary: OpenPaymentLinks.Summary
    let onOpenLinks: () -> Void
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = EnvelopeStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if summary.sentCount > 0 {
                sentLine
                if summary.toClaimCount > 0 { Divider() }
            }
            if summary.toClaimCount > 0 {
                claimLine
            }
        }
    }

    private var sentLine: some View {
        Button(action: onOpenLinks) {
            HStack(spacing: 10) {
                glyph(.secondary)
                sentText
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(OpenPaymentLinks.sentAccessibilityLabel(
            amount: summary.sentAmount, count: summary.sentCount, expired: summary.expiredCount
        ))
        .accessibilityHint(Text("Shows your payment links", comment: "VoiceOver hint: the balance card's open links line"))
        .accessibilityIdentifier("wallet.openLinks.sent")
    }

    /// The amount in the label color, the rest secondary. Same strings as
    /// `OpenPaymentLinks.sentLineText`.
    private var sentText: Text {
        let amount = Text(OpenPaymentLinks.amountText(summary.sentAmount))
            .foregroundStyle(.primary)
            .fontWeight(.medium)
            .monospacedDigit()
        let links = OpenPaymentLinks.openLinksText(count: summary.sentCount)
        let text = Text("\(amount) in \(links)", comment: "Balance card: the money in your open payment links, then how many links")
        guard summary.expiredCount > 0 else { return lineStyle(text) }
        let expired = OpenPaymentLinks.expiredText(count: summary.expiredCount)
        return lineStyle(Text("\(text) · \(expired)", comment: "Balance card: the open links line, then how many of them expired"))
    }

    private var claimLine: some View {
        HStack(spacing: 10) {
            Button(action: onOpenLinks) {
                HStack(spacing: 10) {
                    glyph(.green)
                    claimText
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OpenPaymentLinks.claimLineText(amount: summary.toClaimAmount, count: summary.toClaimCount))
            .accessibilityHint(Text("Shows your payment links", comment: "VoiceOver hint: the balance card's open links line"))
            .accessibilityIdentifier("wallet.openLinks.toClaim")

            Button(action: claim) {
                Text("Claim")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(minHeight: 44)
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(claimHint)
            .accessibilityIdentifier("wallet.openLinks.claim")
        }
    }

    private var claimText: Text {
        guard let amount = summary.toClaimAmount else {
            return lineStyle(Text(OpenPaymentLinks.claimLineText(amount: nil, count: summary.toClaimCount)))
        }
        let styled = Text(OpenPaymentLinks.amountText(amount))
            .foregroundStyle(.primary)
            .fontWeight(.medium)
            .monospacedDigit()
        return lineStyle(Text("\(styled) to claim", comment: "Balance card: money in payment links sent to you, waiting to be claimed"))
    }

    private func lineStyle(_ text: Text) -> Text {
        text
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func glyph(_ style: some ShapeStyle) -> some View {
        Image(systemName: "link")
            .font(.subheadline)
            .foregroundStyle(style)
            .accessibilityHidden(true)
    }

    /// The one link waiting, if there is only one.
    private var onlyLinkToClaim: EnvelopeRecord? {
        let waiting = store.received.filter(OpenPaymentLinks.isWaitingToClaim)
        return waiting.count == 1 ? waiting.first : nil
    }

    private func isReady(_ record: EnvelopeRecord) -> Bool {
        PendingPaymentLinks.state(of: record, daemonHeight: walletManager.daemonHeight) == .ready
    }

    /// One link: the claim sheet, which claims as soon as its check finds
    /// the link ready. More: the Links filter lists them.
    private func claim() {
        guard let record = onlyLinkToClaim else {
            onOpenLinks()
            return
        }
        PaymentLinksCoordinator.shared.present(record, autoClaim: isReady(record))
    }

    private var claimHint: String {
        guard let record = onlyLinkToClaim else {
            return String(localized: "Shows the links to claim", comment: "VoiceOver hint: Claim on the balance card with several links waiting")
        }
        return OpenPaymentLinkRow.claimHint(ready: isReady(record), walletName: walletManager.activeWallet?.name)
    }
}

// MARK: - Open Links group

/// One open link at the top of Activity's Links filter: "Payment link",
/// where it stands, its amount, and the next step as a chip. Claim (a link
/// sent to us) and Reclaim (our expired link) open the claim sheet; Share
/// shares our link again. A tap elsewhere opens the link's detail.
struct OpenPaymentLinkRow: View {
    let item: OpenPaymentLinks.Item
    let onOpen: () -> Void
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var record: EnvelopeRecord { item.record }
    private var isReceived: Bool { record.role == .received }
    private var tint: Color { isReceived ? .green : .brand }

    private var receivedState: PendingPaymentLinks.State {
        PendingPaymentLinks.state(of: record, daemonHeight: walletManager.daemonHeight)
    }

    /// Ours: "Expired", "Waiting to be claimed", "Ready to claim", as its
    /// Activity row says. Sent to us: "Ready in about 12 min", "Ready to
    /// claim" and so on.
    private var statusText: String {
        if isReceived { return PendingPaymentLinks.label(for: receivedState) }
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        return PaymentLinkActivity.fundingStatusLine(status: display.status, isExpired: display.isExpired, confirmations: display.confirmations)
    }

    private var statusColor: Color {
        isReceived && receivedState == .ready ? .green : .secondary
    }

    /// "0.05" for ours, "+0.03" for one sent to us, as Activity rows read.
    private var amountText: String? {
        guard let amount = isReceived ? record.claimAmount : record.amount else { return nil }
        let xmr = XMRFormatter.format(EnvelopeRuntime.xmr(amount))
        return isReceived ? "+\(xmr)" : xmr
    }

    var body: some View {
        Group {
            // At accessibility sizes the amount and the chip go under the
            // title, as Activity rows do.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    openButton(stacked: true)
                    HStack(spacing: 12) {
                        amountLabel
                        chip
                    }
                    .padding(.leading, 48)
                }
            } else {
                HStack(spacing: 12) {
                    openButton(stacked: false)
                    VStack(alignment: .trailing, spacing: 6) {
                        amountLabel
                        chip
                    }
                    .layoutPriority(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("links.open.\(item.id)")
    }

    /// Tile, title and status: opens the detail. VoiceOver reads the amount
    /// here too; the chip is its own button.
    private func openButton(stacked: Bool) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Payment link")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: !stacked, vertical: true)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Text("Shows the link", comment: "VoiceOver hint: an open payment link row in Activity"))
    }

    @ViewBuilder
    private var amountLabel: some View {
        if let amountText {
            Text(amountText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isReceived ? Color.green : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                // The row's open button reads it to VoiceOver.
                .accessibilityHidden(true)
                .onTapGesture(perform: onOpen)
        }
    }

    @ViewBuilder
    private var chip: some View {
        switch item.kind {
        case .toClaim:
            if receivedState != .noMoney {
                Button {
                    PaymentLinksCoordinator.shared.present(record, autoClaim: receivedState == .ready)
                } label: {
                    chipLabel(String(localized: "Claim"), systemImage: nil)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Self.claimHint(ready: receivedState == .ready, walletName: walletManager.activeWallet?.name))
            }
        case .expired:
            Button {
                // Our link: the claim sheet opens on Reclaim and its confirmation.
                PaymentLinksCoordinator.shared.present(record)
            } label: {
                chipLabel(String(localized: "Reclaim"), systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Moves the money in this link back to your wallet"))
        case .waiting, .ready:
            if let item = PaymentLinkShareItem(record: record) {
                PaymentLinkShareButton(item: item) {
                    chipLabel(String(localized: "Share", comment: "Open payment link chip: share the link again"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shares the link again", comment: "VoiceOver hint: Share chip on an open payment link"))
            }
        }
    }

    private func chipLabel(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.brand)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.brand.opacity(0.15), in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
    }

    private var accessibilityText: String {
        let amount: String?
        if isReceived {
            amount = record.claimAmount.map {
                String(localized: "plus \(XMRFormatter.format(EnvelopeRuntime.xmr($0))) XMR", comment: "VoiceOver: amount coming in")
            }
        } else {
            amount = OpenPaymentLinks.amountText(record.amount)
        }
        return [String(localized: "Payment link"), amount, statusText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// VoiceOver hint for Claim on one link.
    static func claimHint(ready: Bool, walletName: String?) -> String {
        if ready, let walletName, !walletName.isEmpty {
            return String(localized: "Claims the money to \(walletName)")
        }
        return String(localized: "Opens the link to claim it")
    }
}

// MARK: - Checks on the dashboard

/// Keeps the balance card's open-link lines true while the dashboard is on
/// screen. A look at a link (`PaymentLinksStatusChecker`) opens its
/// envelope, which stops the active wallet while it runs, so the dashboard
/// looks seldom: once when it appears, when the app comes back to the
/// foreground and after a wallet switch, then at most every 10 minutes
/// while one of the active wallet's links is open. Each look waits for a
/// synced wallet with its history loaded (the checker reads the funding
/// from it), at Now, with no sheet open. Never per block.
struct OpenPaymentLinksChecks: ViewModifier {
    /// False while History is open, a sheet is up or the wallet list shows.
    let isActive: Bool
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = EnvelopeStore.shared
    @ObservedObject private var coordinator = PaymentLinksCoordinator.shared
    @StateObject private var checker = PaymentLinksStatusChecker()
    @State private var isOnScreen = false
    /// The dashboard appeared, the app came back or the wallet changed:
    /// look once the wallet allows it.
    @State private var isDue = false
    @State private var lastLook: Date?

    static let lookInterval: TimeInterval = 10 * 60

    static func isLookDue(isDue: Bool, lastLook: Date?, now: Date) -> Bool {
        guard !isDue, let lastLook else { return true }
        return now.timeIntervalSince(lastLook) >= lookInterval
    }

    private var canCheck: Bool { isActive && coordinator.presentation == nil }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                isDue = true
                store.reload()
                check()
            }
            .onDisappear {
                isOnScreen = false
                stop()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    check()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                isDue = true
                check()
            }
            .onChange(of: walletManager.activeWallet?.id) { _, _ in
                isDue = true
                check()
            }
            .onChange(of: walletManager.daemonHeight) { _, _ in check() }
            .onChange(of: walletManager.syncState) { _, _ in check() }
            .onChange(of: walletManager.transactions.isEmpty) { _, _ in check() }
            .onChange(of: canCheck) { _, can in
                if can { check() } else { stop() }
            }
    }

    private func stop() {
        // A look cut short runs again once the wallet allows it.
        if checker.isChecking { isDue = true }
        checker.stop()
    }

    private func check(now: Date = Date()) {
        // An empty history right after a start is not loaded yet: the
        // checker would take every pending link for one funded elsewhere.
        guard isOnScreen, canCheck, walletManager.syncState == .synced,
              !walletManager.transactions.isEmpty else { return }
        // From the active wallet's history alone: no envelope, every time.
        PaymentLinksStatusChecker.reconcileFunding(store: store, walletManager: walletManager)
        PaymentLinksStatusChecker.forgetMinedClaimWords(store: store, walletManager: walletManager)
        PaymentLinksStatusChecker.fillNetAmounts(store: store, walletManager: walletManager)
        guard Self.isLookDue(isDue: isDue, lastLook: lastLook, now: now) else { return }
        isDue = false
        let activeId = walletManager.activeWallet?.id.uuidString
        guard store.sent.contains(where: { OpenPaymentLinks.isOpenSent($0, activeWalletId: activeId) }) else { return }
        lastLook = now
        checker.start(walletManager: walletManager, store: store, matching: {
            OpenPaymentLinks.isOpenSent($0, activeWalletId: activeId)
        })
    }
}

extension View {
    /// The dashboard: keeps the balance card's open-link lines true.
    func checksOpenPaymentLinks(isActive: Bool) -> some View {
        modifier(OpenPaymentLinksChecks(isActive: isActive))
    }
}
