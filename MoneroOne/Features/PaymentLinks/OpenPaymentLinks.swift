import SwiftUI

// MARK: - Open links

/// Payment links that still hold money: links this wallet sent that nobody
/// claimed or reclaimed yet (waiting, ready or expired), and links sent to
/// this device that wait to be claimed here. The balance card sums them in
/// one or two lines. Activity's Links filter shows each link once: ours as
/// its "Sent by Link" row, one sent to us as a row of its own until its
/// claim is a transaction (`PaymentLinkToClaimRow`). Android ports the same
/// rules.
enum OpenPaymentLinks {
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
        // A link with a funding transaction is open whatever a check that
        // missed the funding wrote; one without is hidden.
        let status = EnvelopeStatusRules.reconciled(record.status, role: record.role, fundingTxid: record.fundingTxid)
        guard record.role == .sent, status == .pending || status == .ready else { return false }
        if let walletId = record.walletId, walletId != activeWalletId { return false }
        return true
    }

    /// A received link this device can still claim: not settled, and it
    /// still has the secret. Pending money or not, it is open.
    static func isToClaim(_ record: EnvelopeRecord) -> Bool {
        record.role == .received && !record.status.isSettled && record.link != nil
    }

    /// A received link that waits to be claimed: `isToClaim`, unless its
    /// money never arrived in its days to claim. That one is History, as
    /// Expired, until money shows up.
    static func isWaitingToClaim(_ record: EnvelopeRecord, now: Date = Date()) -> Bool {
        isToClaim(record) && !record.isReceivedExpired(now: now)
    }

    static func summary(of records: [EnvelopeRecord], activeWalletId: String?, now: Date = Date()) -> Summary {
        var summary = Summary()
        for record in records {
            if isOpenSent(record, activeWalletId: activeWalletId) {
                summary.sentCount += 1
                summary.sentAmount += record.amount
                if record.isExpired(now: now) { summary.expiredCount += 1 }
            } else if isWaitingToClaim(record, now: now) {
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

    // MARK: Text

    static func amountText(_ piconero: UInt64) -> String {
        "\(XMRFormatter.format(EnvelopeRuntime.xmr(piconero))) XMR"
    }

    /// The amount a balance card line shows: `fiat`, its value at today's
    /// price, in Fiat Mode (nil outside it or with no price), else XMR.
    static func lineAmount(_ piconero: UInt64, fiat: String?) -> String {
        fiat ?? amountText(piconero)
    }

    /// "2 open links", "1 open link".
    static func openLinksText(count: Int) -> String {
        String(localized: "\(count) open links", comment: "Balance card: payment links you sent that nobody claimed yet")
    }

    /// "1 expired".
    static func expiredText(count: Int) -> String {
        String(localized: "\(count) expired", comment: "Balance card: how many of your open payment links expired")
    }

    /// "0.15 XMR in 2 open links", "$83.52 in 2 open links" in Fiat Mode.
    static func sentText(amount: UInt64, fiat: String? = nil, count: Int) -> String {
        String(localized: "\(lineAmount(amount, fiat: fiat)) in \(openLinksText(count: count))", comment: "Balance card: the money in your open payment links, then how many links")
    }

    /// The sent line as it reads: "0.15 XMR in 2 open links · 1 expired".
    static func sentLineText(amount: UInt64, fiat: String? = nil, count: Int, expired: Int) -> String {
        let text = sentText(amount: amount, fiat: fiat, count: count)
        guard expired > 0 else { return text }
        return String(localized: "\(text) · \(expiredText(count: expired))", comment: "Balance card: the open links line, then how many of them expired")
    }

    /// VoiceOver: "0.15 XMR in 2 open links, 1 expired".
    static func sentAccessibilityLabel(amount: UInt64, fiat: String? = nil, count: Int, expired: Int) -> String {
        let text = sentText(amount: amount, fiat: fiat, count: count)
        guard expired > 0 else { return text }
        return [text, expiredText(count: expired)].joined(separator: ", ")
    }

    /// What the claims bring, an estimate as on their Activity rows and
    /// the claim sheet: "~0.03 XMR", "~$16.70" in Fiat Mode.
    static func claimAmountText(_ piconero: UInt64, fiat: String?) -> String {
        "~" + lineAmount(piconero, fiat: fiat)
    }

    /// "~0.03 XMR to claim"; "2 links to claim" while an amount is not
    /// known.
    static func claimLineText(amount: UInt64?, fiat: String? = nil, count: Int) -> String {
        if let amount {
            return String(localized: "\(claimAmountText(amount, fiat: fiat)) to claim", comment: "Balance card: money in payment links sent to you, waiting to be claimed")
        }
        return String(localized: "\(count) links to claim", comment: "Balance card: payment links sent to you, amount not known yet")
    }

    /// VoiceOver: "about 0.03 XMR to claim".
    static func claimAccessibilityLabel(amount: UInt64?, fiat: String? = nil, count: Int) -> String {
        guard let amount else { return claimLineText(amount: nil, count: count) }
        let about = String(localized: "about \(lineAmount(amount, fiat: fiat))", comment: "VoiceOver: an estimated amount")
        return String(localized: "\(about) to claim", comment: "Balance card: money in payment links sent to you, waiting to be claimed")
    }

    /// VoiceOver hint for Claim on one link.
    static func claimHint(ready: Bool, walletName: String?) -> String {
        if ready, let walletName, !walletName.isEmpty {
            return String(localized: "Claims the money to \(walletName)")
        }
        return String(localized: "Opens the link to claim it")
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
    @EnvironmentObject var priceService: PriceService
    @ObservedObject private var store = EnvelopeStore.shared

    /// In Fiat Mode, what `piconero` is worth at today's price, as the
    /// Activity rows show it; nil outside Fiat Mode or with no price.
    private func fiat(_ piconero: UInt64?) -> String? {
        guard priceService.showFiatFirst, let piconero else { return nil }
        return priceService.formatFiatValue(EnvelopeRuntime.xmr(piconero))
    }

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
            amount: summary.sentAmount, fiat: fiat(summary.sentAmount), count: summary.sentCount, expired: summary.expiredCount
        ))
        .accessibilityHint(Text("Shows your payment links", comment: "VoiceOver hint: the balance card's open links line"))
        .accessibilityIdentifier("wallet.openLinks.sent")
    }

    /// The amount in the label color, the rest secondary. Same strings as
    /// `OpenPaymentLinks.sentLineText`.
    private var sentText: Text {
        let amount = Text(OpenPaymentLinks.lineAmount(summary.sentAmount, fiat: fiat(summary.sentAmount)))
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
            .accessibilityLabel(OpenPaymentLinks.claimAccessibilityLabel(
                amount: summary.toClaimAmount, fiat: fiat(summary.toClaimAmount), count: summary.toClaimCount
            ))
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
        let styled = Text(OpenPaymentLinks.claimAmountText(amount, fiat: fiat(amount)))
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
        let waiting = store.received.filter { OpenPaymentLinks.isWaitingToClaim($0) }
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
        return OpenPaymentLinks.claimHint(ready: isReady(record), walletName: walletManager.activeWallet?.name)
    }
}

// MARK: - Links to claim in Activity

/// A link sent to us that waits to be claimed, in Activity. Its claim is
/// not a transaction yet, so it is drawn as money coming in, with the
/// transaction rows' layout: the green arrow with the link badge, the
/// link's name, the date it was opened, what the claim brings (an
/// estimate that follows Fiat Mode) and where it stands (Ready to claim,
/// Waiting). A tap opens the claim sheet, where the wallet is chosen.
struct PaymentLinkToClaimRow: View {
    let record: EnvelopeRecord
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService

    private var state: PendingPaymentLinks.State {
        PendingPaymentLinks.state(of: record, daemonHeight: walletManager.daemonHeight)
    }

    /// Nil while the claim's amount is not known (a link not checked yet).
    private var amount: TransactionAmountText? {
        guard let piconero = record.claimAmount else { return nil }
        let xmr = EnvelopeRuntime.xmr(piconero)
        return .incomingEstimate(xmr: xmr, fiatNow: priceService.formatFiatValue(xmr), fiatFirst: priceService.showFiatFirst)
    }

    /// As the transaction rows write it.
    private var date: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: record.createdAt)
    }

    var body: some View {
        let status = PaymentLinkRowStatus.toClaim(state)
        let amount = self.amount
        Button {
            PaymentLinksCoordinator.shared.present(record)
        } label: {
            ActivityRowLayout(
                systemImage: "arrow.down.left",
                isIncoming: true,
                showsLinkBadge: true,
                title: record.displayName,
                subtitle: date
            ) { alignment in
                if let amount {
                    TransactionAmountColumn(amount: amount, isIncoming: true, linkStatus: status, alignment: alignment)
                } else {
                    PaymentLinkStatusLabel(status: status)
                }
            }
            // The chevron the transaction rows' links get, so the amounts
            // line up.
            .listRowDisclosure()
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Self.accessibilityLabel(name: record.displayName, amountSpoken: amount?.spoken, status: status.text, date: date))
        .accessibilityHint(String(localized: "Opens the link to claim it"))
        .accessibilityIdentifier("links.toClaim.\(record.id)")
    }

    /// "Payment link, Link 7, plus about 0.0154 XMR, worth about $2.47,
    /// Ready to claim, Oct 16, 2026 at 8:12 PM".
    static func accessibilityLabel(name: String, amountSpoken: String?, status: String, date: String) -> String {
        PaymentLinkActivity.accessibilityLabel(
            kind: String(localized: "Payment link"),
            name: name,
            isIncoming: true,
            amountSpoken: amountSpoken,
            status: status,
            date: date
        )
    }
}

extension View {
    /// A trailing chevron like a List row's NavigationLink.
    func listRowDisclosure() -> some View {
        HStack(spacing: 0) {
            self
            ListRowChevron()
        }
    }
}

/// Measured against the system's disclosure chevron: size, color and
/// place.
private struct ListRowChevron: View {
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 14

    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .accessibilityHidden(true)
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
