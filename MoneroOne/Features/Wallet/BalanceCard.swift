import SwiftUI

struct BalanceCard: View {
    let balance: Decimal
    let unlockedBalance: Decimal
    let syncState: WalletManager.SyncState
    let connectionStage: ConnectionStage
    @ObservedObject var priceService: PriceService
    var isViewOnly: Bool = false
    var isHardwareWallet: Bool = false
    var hardwareDeviceName: String? = nil
    var hardwareLastSentSyncAt: Date? = nil
    var isHardwareDeviceWarm: Bool = false
    var isSyncBlocked: Bool = false
    var isOutsideTrustedZone: Bool = false
    var trustedLocationName: String? = nil
    var isTrustedLocationEnabled: Bool = false
    var isHistoryExpanded: Binding<Bool> = .constant(false)
    var selectedHistoryPoint: Binding<PortfolioDataPoint?> = .constant(nil)
    var selectedHistoryRange: Binding<ChartTimeRange> = .constant(.week)
    var historyModel = BalanceHistoryModel()
    /// Payment links that still hold money, for the lines under the balance.
    var openLinks = OpenPaymentLinks.Summary()
    /// Opens Activity's Links filter. Nil: no open-link lines.
    var onOpenLinks: (() -> Void)? = nil
    var onHardwareSyncTap: (() -> Void)? = nil
    /// The balance the hero shows while payments wait for their Money
    /// arrives moment. Nil: `balance`.
    var heroBalance: Decimal? = nil
    /// Money arrives: the moment to play, once.
    var arrival: MoneyArrival? = nil
    /// The moment settled.
    var onArrivalDone: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var balanceSize: CGFloat = 32
    /// The history chart is built on first open and then kept, closed, so
    /// reopening and switching ranges never rebuild it.
    @State private var isHistoryMounted = false
    /// The first open builds the chart closed, then opens it once laid out.
    @State private var opensHistoryOnMount = false
    /// Where the open History sits in the card. A tap there is the chart's,
    /// so a near miss on the chart, Now or a range does not close History.
    @State private var historyFrame: CGRect = .null
    private static let cardSpace = "BalanceCard"
    /// Money arrives: the moment whose +amount rose into the hero.
    @State private var risenArrivalId: UUID?
    @State private var arrivalStep = ArrivalStep.idle
    @State private var hidesCaption = false
    @State private var isHeroGreen = false
    @State private var shineOffset: CGFloat = -1.5

    private var historicalPoint: PortfolioDataPoint? { selectedHistoryPoint.wrappedValue }
    private var showsOpenLinks: Bool { onOpenLinks != nil && !openLinks.isEmpty }
    private var displayedBalance: Decimal { historicalPoint?.balance ?? shownBalance }

    /// Now: the moment's old balance until its +amount rises, else the
    /// held balance, else the wallet's.
    private var shownBalance: Decimal {
        if let arrival, risenArrivalId != arrival.id {
            return arrival.fromBalance
        }
        return heroBalance ?? balance
    }

    /// A historical amount uses the sampled price at that same moment.
    private var fiatBalance: String? {
        if let historicalPoint {
            return priceService.formatFiat(Decimal(historicalPoint.value))
        }
        return priceService.formatFiatValue(shownBalance)
    }

    /// Fiat Mode puts the fiat balance in the hero and the XMR amount under
    /// it. With no price yet the card keeps XMR on top.
    private var isFiatFirst: Bool {
        priceService.showFiatFirst && fiatBalance != nil
    }

    /// The hero number: "1.2345" beside an "XMR" unit, or "$150.23".
    private var heroText: String {
        isFiatFirst ? fiatBalance ?? "" : XMRFormatter.format(displayedBalance)
    }

    /// The line under the hero: "≈ $150.23", or "1.2345 XMR" in Fiat Mode.
    private var captionText: String? {
        if isFiatFirst {
            return "\(XMRFormatter.format(displayedBalance)) XMR"
        }
        return fiatBalance.map { "≈ \($0)" }
    }

    private func viewOnlyPill(showsText: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.caption2)
            if showsText {
                Text("View-only")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(.brand)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.brand.opacity(0.15)))
    }

    private var balanceAccessibilityLabel: String {
        if let historicalPoint {
            let date = historicalPoint.timestamp.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Historical balance: \(XMRFormatter.format(displayedBalance)) XMR, \(fiatBalance ?? ""), as of \(date)")
        }
        if isFiatFirst, let fiatBalance {
            return String(localized: "Balance: \(fiatBalance), \(XMRFormatter.format(displayedBalance)) XMR", comment: "VoiceOver: Fiat Mode balance, fiat first, then XMR")
        }
        let approximately = fiatBalance.map { String(localized: ", approximately \($0)", comment: "VoiceOver: fiat value after an XMR amount") } ?? ""
        return String(localized: "Balance: \(XMRFormatter.format(displayedBalance)) XMR\(approximately)")
    }

    private var availableAccessibilityLabel: String {
        let xmr = XMRFormatter.format(unlockedBalance)
        let fiat = priceService.formatFiatValue(unlockedBalance)
        let amounts: String
        if isFiatFirst, let fiat {
            amounts = "\(fiat), \(xmr) XMR"
        } else {
            amounts = "\(xmr) XMR" + (fiat.map { String(localized: ", approximately \($0)", comment: "VoiceOver: fiat value after an XMR amount") } ?? "")
        }
        return String(localized: "Available balance: \(amounts). Some funds locked until recent transactions confirm.", comment: "VoiceOver: spendable balance while some funds are locked; %@ is the amount")
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .statusLine) {
                // The past covers the status and pills without replacing
                // them, so the row keeps its height while scrubbing.
                ZStack(alignment: Alignment(horizontal: .leading, vertical: .statusLine)) {
                    HStack(alignment: .statusLine) {
                        syncStatus
                        devicePill
                        // A sync error fills the free width itself. Beside
                        // this Spacer, the row gave a wrapping error 8pt too
                        // much, and the pill covered the gap before History.
                        if !showsSyncError {
                            Spacer(minLength: 0)
                        }
                    }
                    .opacity(historicalPoint == nil ? 1 : 0)
                    .accessibilityHidden(historicalPoint != nil)

                    if historicalPoint != nil {
                        Label("Historical balance", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                historyToggle
            }

            VStack(spacing: 0) {
                balanceRow

                if isHistoryMounted || isHistoryExpanded.wrappedValue {
                    historyChart
                }
            }

            // Unlocked Balance
            if unlockedBalance != shownBalance {
                availableRow
                    // Kept in place while viewing the past so the card does not shrink.
                    .opacity(historicalPoint == nil ? 1 : 0)
                    .accessibilityHidden(historicalPoint != nil)
            }

            // Hardware-wallet "sent transactions may be out of date" banner.
            // Block-scan only sees incoming outputs from a view key; outgoing
            // transactions need a key-image sync against the device. This row
            // makes the limitation visible and offers a one-tap path to fix it.
            if isHardwareWallet {
                Button {
                    onHardwareSyncTap?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.medium))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync Sent Transactions")
                                .font(.caption.weight(.semibold))
                            Text(lastSentSyncSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync sent transactions — \(lastSentSyncSubtitle)")
                .accessibilityHint("Connects your hardware wallet briefly to update the list of outgoing transactions.")
            }

            // Sync Progress (hidden when blocked)
            if !isSyncBlocked, case .syncing(let progress, let remaining) = syncState {
                VStack(spacing: 4) {
                    ProgressView(value: progress / 100)
                        .tint(.brand)
                        .accessibilityHidden(true)
                    if let remaining = remaining {
                        Text("\(Int(progress))% synced - \(formatBlockCount(remaining)) blocks remaining")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(Int(progress))% synced")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sync progress: \(Int(progress)) percent\(remaining.map { String(localized: ", \(formatBlockCount($0)) blocks remaining", comment: "VoiceOver: after the sync percent") } ?? "")")
            }

            // Trusted location status
            if isSyncBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Sync paused — outside trusted zone")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: sync paused, outside trusted zone")
            } else if isOutsideTrustedZone {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.yellow)
                        .accessibilityHidden(true)
                    Text("Syncing from untrusted location")
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: warning, syncing from untrusted location")
            } else if isTrustedLocationEnabled, let name = trustedLocationName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Syncing from \(name)")
                        .font(.caption)
                }
                .foregroundColor(.green)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: trusted, syncing from \(name)")
            }

            // Money still in payment links: the live balance only. Kept in
            // place while scrubbing History, so the card keeps its height.
            if showsOpenLinks, let onOpenLinks {
                OpenPaymentLinkLines(summary: openLinks, onOpenLinks: onOpenLinks)
                    .opacity(historicalPoint == nil ? 1 : 0)
                    .accessibilityHidden(historicalPoint != nil)
                    .allowsHitTesting(historicalPoint == nil)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        // The lines are 44 tall; their own space closes the card.
        .padding(.bottom, showsOpenLinks ? 12 : 24)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
        // A tap anywhere on the card opens and closes History, as the
        // History button does. The buttons keep their own taps, the open
        // History keeps its taps and scrub, and a drag still scrolls.
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture(coordinateSpace: .named(Self.cardSpace)) { location in
            if isHistoryExpanded.wrappedValue && historyFrame.contains(location) { return }
            toggleHistory()
        }
        .coordinateSpace(.named(Self.cardSpace))
        .task(id: arrival?.id) { await playArrival() }
    }

    // MARK: - Status row

    /// The status row shows a sync error, which can wrap.
    private var showsSyncError: Bool {
        guard !isSyncBlocked, case .error = syncState else { return false }
        return true
    }

    @ViewBuilder
    private var syncStatus: some View {
        if isSyncBlocked {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("Paused")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel("Sync status: paused")
        } else if case .synced = syncState {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("Synced")
                .font(.caption)
                .foregroundColor(.secondary)
                // One line at full width: squeezed by a long pill,
                // "Синхронизировано" broke with a hyphen.
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Sync status: synced")
        } else if case .error(let msg) = syncState {
            // One view with its dot. It fills the width before the pill,
            // so the error wraps there and the pill stays beside line 1.
            HStack(alignment: .statusLine) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Error: \(msg)")
                    .font(.caption)
                    .foregroundColor(.red)
                    // A long error, such as the node login error, wraps. The
                    // row centers on its first line, so the dot, the pill and
                    // History stay beside that line as on one line.
                    .alignmentGuide(.statusLine) { d in
                        (d.height - (d[.lastTextBaseline] - d[.firstTextBaseline])) / 2
                    }
                    .accessibilityLabel("Sync error: \(msg)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ConnectionStepIndicator(
                stage: connectionStage,
                syncProgress: syncProgress
            )
        }
    }

    @ViewBuilder
    private var devicePill: some View {
        if isHardwareWallet {
            Button {
                onHardwareSyncTap?()
            } label: {
                HStack(spacing: 5) {
                    // Two-state pill: its hue is the
                    // primary visual signal so connection
                    // state is impossible to miss at a
                    // glance. Green = device link is live
                    // (BLE connected, THP up, bridge ready
                    // — anything we could send to right
                    // now). Gray = idle, next tap will go
                    // through the full BLE/THP bringup.
                    Image(systemName: isHardwareDeviceWarm ? "bolt.fill" : "bolt.slash.fill")
                        .font(.caption2.weight(.bold))
                    Text(isHardwareDeviceWarm
                         ? String(localized: "\(hardwareDeviceName ?? "Trezor") • Live", comment: "Hardware wallet pill: device name, then that the link is up")
                         : (hardwareDeviceName ?? "Trezor"))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(isHardwareDeviceWarm ? Color.green : Color.gray)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill((isHardwareDeviceWarm ? Color.green : Color.gray).opacity(0.15))
                )
                .padding(.leading, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(hardwareDeviceName ?? String(localized: "Hardware wallet"))\(isHardwareDeviceWarm ? String(localized: ", connected") : String(localized: ", not connected")). Tap to sync sent transactions.")
        } else if isViewOnly {
            // The eye alone when the word does not fit beside the
            // status: "Solo visualizzazione" and "Только просмотр"
            // wrapped inside the pill. A sync error wraps beside it, so
            // the error gets the eye alone and the rest of the row.
            Group {
                if showsSyncError {
                    viewOnlyPill(showsText: false)
                } else {
                    ViewThatFits(in: .horizontal) {
                        viewOnlyPill(showsText: true)
                        viewOnlyPill(showsText: false)
                    }
                }
            }
            .padding(.leading, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("View-only wallet")
        }
    }

    private var historyToggle: some View {
        Button {
            toggleHistory()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line")
                Text("History")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isHistoryExpanded.wrappedValue ? 180 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.brand)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brand.opacity(0.12), in: Capsule())
            // Keep the compact status row while providing a 44pt target.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wallet.historyToggle")
        .accessibilityLabel("Balance history")
        .accessibilityValue(isHistoryExpanded.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityHint(isHistoryExpanded.wrappedValue ? "Hides balance history and returns to now" : "Shows your balance over time")
    }

    // MARK: - Balance

    private var balanceRow: some View {
        HStack(spacing: 16) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .scaleEffect(1.15)
                .clipShape(Circle())
                .accessibilityHidden(true)

            // At least 44 pt tall; a tap here is the card's, as anywhere on it.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        heroNumber
                            .foregroundStyle(isHeroGreen ? Color.green : Color.primary)
                            .overlay { heroShine }

                        if !isFiatFirst {
                            Text("XMR")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(heroAnimation, value: heroText)

                    if captionText != nil || arrival != nil {
                        Text(captionText ?? " ")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(digitAnimation, value: captionText)
                            .opacity(captionText == nil || hidesCaption ? 0 : 1)
                            .overlay(alignment: .leading) { arrivalPlus }
                    }
                }

                Spacer()
            }
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(balanceAccessibilityLabel)
        .accessibilityIdentifier("wallet.balanceValue")
        .accessibilityAction(named: isHistoryExpanded.wrappedValue ? "Hide history" : "Show history") {
            toggleHistory()
        }
    }

    /// Digits roll like the Price header: briskly while a finger scrubs
    /// the History chart, a little slower for live balance changes.
    private var digitAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: historicalPoint == nil ? 0.2 : 0.1)
    }

    /// The hero's roll. Reduce Motion: a Money arrives moment cross-fades
    /// the new balance in (crossFade).
    private var heroAnimation: Animation? {
        if reduceMotion, arrival != nil { return .easeInOut(duration: 0.35) }
        return digitAnimation
    }

    private var heroNumber: some View {
        Text(heroText)
            .font(.system(size: balanceSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    // MARK: - Money arrives

    private enum ArrivalStep {
        /// No +amount.
        case idle
        /// The +amount sits in the caption's place.
        case shown
        /// The +amount rose into the balance and faded.
        case risen
    }

    /// "1.2845 XMR", or "$440.22" in Fiat Mode.
    private var arrivalAmountText: String? {
        guard let arrival else { return nil }
        if isFiatFirst, let fiat = priceService.formatFiatValue(arrival.amount) {
            return fiat
        }
        return "\(XMRFormatter.format(arrival.amount)) XMR"
    }

    /// "+1.2845 XMR", or "+$440.22" in Fiat Mode.
    private var arrivalPlusText: String? {
        arrivalAmountText.map { "+\($0)" }
    }

    /// VoiceOver says each moment once: "Received 1.2845 XMR".
    private func announceArrival() {
        guard let amount = arrivalAmountText else { return }
        let text = String(
            localized: "Received \(amount)",
            comment: "VoiceOver: a payment arrived on the balance card. The amount is in XMR, or in the fiat currency in Fiat Mode"
        )
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    @ViewBuilder
    private var arrivalPlus: some View {
        if let arrivalPlusText, let arrival {
            Text(arrivalPlusText)
                .font(arrival.isFirstPayment ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .opacity(arrivalStep == .shown ? 1 : 0)
                .offset(y: arrivalOffset)
                .accessibilityHidden(true)
        }
    }

    /// arrive: up 20 pt into place; then 20 pt more into the balance.
    private var arrivalOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        switch arrivalStep {
        case .idle: return 20
        case .shown: return 0
        case .risen: return -20
        }
    }

    /// The first payment's single heroShine across the green balance.
    @ViewBuilder
    private var heroShine: some View {
        if arrival?.isFirstPayment == true, !reduceMotion {
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.3), .white.opacity(0.6), .white.opacity(0.3), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.35)
                .blur(radius: 8)
                .offset(x: shineOffset * geo.size.width)
                .animation(.easeInOut(duration: 1.2), value: shineOffset)
            }
            .mask { heroNumber }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The moment, from the mockup. Every payment: the caption fades out
    /// and the green +amount arrives in its place; at 0.55 s it rises into
    /// the balance, which rolls, the Available line discloses and a soft
    /// tap plays; the caption returns at 0.8 s. The first payment: a bigger
    /// +amount; at 0.65 s the balance rolls and turns green, the success
    /// haptic at 0.8 s, one shine at 1.0 s, back to the label color at
    /// 2.0 s. Reduce Motion: fades only, no shine; haptics stay.
    private func playArrival() async {
        guard let arrival, risenArrivalId != arrival.id else { return }
        let isFirst = arrival.isFirstPayment
        let rise = isFirst ? 0.65 : 0.55
        let captionBack = reduceMotion ? 0.8 : rise + 0.25
        var clock = 0.0
        var isAnnounced = false
        func wait(until time: Double) async throws {
            if time > clock { try await Task.sleep(for: .seconds(time - clock)) }
            clock = max(clock, time)
        }
        do {
            withAnimation(.easeInOut(duration: 0.2)) { hidesCaption = true }
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.2)) { arrivalStep = .shown }
            } else {
                try await wait(until: 0.1)
                withAnimation(.easeOut(duration: 0.4)) { arrivalStep = .shown }
            }

            try await wait(until: rise)
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeIn(duration: 0.25)) { arrivalStep = .risen }
            // disclose: the Available line and the card's growth. The
            // activity list under the card drops other animations; this one
            // moves it with the card.
            var disclose = Transaction(animation: reduceMotion ? .easeInOut(duration: 0.35) : .spring(response: 0.3, dampingFraction: 0.8))
            disclose.isHistoryDisclosure = true
            withTransaction(disclose) {
                risenArrivalId = arrival.id
            }
            announceArrival()
            isAnnounced = true
            if isFirst {
                withAnimation(.easeInOut(duration: 0.35)) { isHeroGreen = true }
            } else {
                HapticFeedback.shared.softTick()
            }

            try await wait(until: 0.8)
            if isFirst { HapticFeedback.shared.transactionSuccess() }

            try await wait(until: captionBack)
            withAnimation(.easeInOut(duration: 0.2)) { hidesCaption = false }

            if isFirst {
                if !reduceMotion {
                    try await wait(until: 1.0)
                    shineOffset = 1.5
                }
                try await wait(until: 2.0)
                withAnimation(.easeInOut(duration: 0.35)) { isHeroGreen = false }
                try await wait(until: 2.35)
            } else {
                try await wait(until: 1.05)
            }
        } catch {
            // Off screen meanwhile: land on the end state.
        }
        if !isAnnounced { announceArrival() }
        risenArrivalId = arrival.id
        arrivalStep = .idle
        hidesCaption = false
        isHeroGreen = false
        onArrivalDone()
    }

    private var availableRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Available:")
                    .foregroundColor(.secondary)
                if isFiatFirst, let fiat = priceService.formatFiatValue(unlockedBalance) {
                    Text(fiat)
                        .fontWeight(.medium)
                    Text("(\(XMRFormatter.format(unlockedBalance)) XMR)")
                        .foregroundColor(.secondary)
                } else {
                    Text(XMRFormatter.format(unlockedBalance))
                        .fontWeight(.medium)
                    Text("XMR")
                        .foregroundColor(.secondary)
                    if let fiat = priceService.formatFiatValue(unlockedBalance) {
                        Text("(\(fiat))")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .font(.subheadline)

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("Locked until recent transactions confirm")
                    .font(.caption2)
            }
            .foregroundColor(.brand)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(availableAccessibilityLabel)
    }

    // MARK: - History

    /// Lives under the amount. It keeps its full layout while closed; only
    /// its frame, clip and opacity animate, so opening and closing never
    /// lay the chart out again and everything below moves with the card.
    private var historyChart: some View {
        BalanceHistoryChart(
            balance: balance,
            isActive: isHistoryExpanded.wrappedValue,
            model: historyModel,
            priceService: priceService,
            selectedTimeRange: selectedHistoryRange,
            selectedPoint: selectedHistoryPoint
        )
        .padding(.top, 16)
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: isHistoryExpanded.wrappedValue ? nil : 0, alignment: .top)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.cardSpace)) } action: { historyFrame = $0 }
        .clipShape(HistoryRevealClip())
        .opacity(isHistoryExpanded.wrappedValue ? 1 : 0)
        .allowsHitTesting(isHistoryExpanded.wrappedValue)
        .accessibilityHidden(!isHistoryExpanded.wrappedValue)
        .onAppear {
            // First open: the chart is laid out closed, then opens.
            if opensHistoryOnMount {
                opensHistoryOnMount = false
                setHistoryExpanded(true)
            }
        }
    }

    private func toggleHistory() {
        if isHistoryExpanded.wrappedValue {
            // Back to now without animation, so the activity list swaps
            // its rows in place while the card closes around it.
            selectedHistoryPoint.wrappedValue = nil
            isHistoryMounted = true
            setHistoryExpanded(false)
        } else if isHistoryMounted {
            setHistoryExpanded(true)
        } else {
            opensHistoryOnMount = true
            isHistoryMounted = true
        }
    }

    private func setHistoryExpanded(_ expanded: Bool) {
        var transaction = Transaction(animation: reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85))
        transaction.isHistoryDisclosure = true
        withTransaction(transaction) {
            isHistoryExpanded.wrappedValue = expanded
        }
    }

    /// Subtitle copy for the hardware-wallet sync banner — surfaces
    /// when the user last brought their device online for a key-image
    /// sync. Falls back to a "may be out of date" prompt if we've never
    /// run one.
    private var lastSentSyncSubtitle: String {
        guard let last = hardwareLastSentSyncAt else {
            return String(localized: "Outgoing transactions may be out of date")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let stamp = formatter.localizedString(for: last, relativeTo: Date())
        return String(localized: "Last synced \(stamp)", comment: "Relative time, e.g. 5 min. ago")
    }

    /// Extract sync progress from syncState for the step indicator
    private var syncProgress: Double? {
        if case .syncing(let progress, _) = syncState {
            return progress
        }
        return nil
    }

    private func formatBlockCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

private extension VerticalAlignment {
    /// The middle of the status row's first line. Only a sync error that
    /// wraps sets it. Everywhere else it is the center, so the row looks as
    /// it did with center alignment.
    enum StatusLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[VerticalAlignment.center]
        }
    }

    static let statusLine = VerticalAlignment(StatusLine.self)
}

/// Clips the history reveal at its top and bottom only, so chart dots and
/// glass at the sides are not cut while it opens.
private struct HistoryRevealClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -24, dy: 0))
    }
}

// MARK: - Connection Step Indicator

/// Progressive connection status indicator with 6 stages
/// Shows: Network -> Node -> Connecting -> Loading -> Syncing -> Synced
private struct ConnectionStepIndicator: View {
    let stage: ConnectionStage
    let syncProgress: Double?  // nil if not syncing, 0-100 if syncing

    private let stageCount = 6
    private let dotSize: CGFloat = 8
    private let lineWidth: CGFloat = 12
    private let lineHeight: CGFloat = 2

    var body: some View {
        // When the connection stage reaches synced, collapse to the same
        // simple green-dot pill the outer view shows when wallet2's
        // syncState is .synced. Without this, a brief drift between the
        // two state machines (e.g. connectionStage = .synced while
        // syncState is still .syncing(100%)) renders the full
        // 5-orange + green ladder labelled "Synced", which looks broken.
        if stage == .synced {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Synced")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync status: synced")
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(0..<stageCount, id: \.self) { index in
                        stepDot(for: index)

                        if index < stageCount - 1 {
                            stepLine(for: index)
                        }
                    }
                }
                .accessibilityHidden(true)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection status: \(statusText)")
        }
    }

    @ViewBuilder
    private func stepDot(for index: Int) -> some View {
        let isCompleted = index < stage.stageIndex
        let isActive = index == stage.stageIndex
        let isFinal = index == stageCount - 1 && stage == .synced

        ZStack {
            if isCompleted || isFinal {
                // Completed or final synced state - filled dot
                Circle()
                    .fill(isFinal ? Color.green : Color.brand)
                    .frame(width: dotSize, height: dotSize)
            } else if isActive {
                // Active state - pulsing dot
                Circle()
                    .fill(Color.brand)
                    .frame(width: dotSize, height: dotSize)
                    .modifier(PulsingModifier())
            } else {
                // Pending state - gray outline
                Circle()
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1.5)
                    .frame(width: dotSize, height: dotSize)
            }
        }
    }

    private func stepLine(for index: Int) -> some View {
        Rectangle()
            .fill(index < stage.stageIndex ? Color.brand : Color.gray.opacity(0.3))
            .frame(width: lineWidth, height: lineHeight)
    }

    private var statusText: String {
        if case .syncing = stage, let progress = syncProgress {
            return String(localized: "Scanning \(Int(progress))%...", comment: "Sync status with percent")
        }
        return stage.displayText
    }
}

/// Pulsing animation modifier for active dots
private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 0.9)
            .opacity(isPulsing ? 1.0 : 0.7)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true)
                ) {
                    isPulsing = true
                }
            }
    }
}

#Preview("Synced") {
    BalanceCard(
        balance: 1.234567890123,
        unlockedBalance: 1.234567890123,
        syncState: .synced,
        connectionStage: .synced,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Syncing") {
    BalanceCard(
        balance: 5.5,
        unlockedBalance: 3.2,
        syncState: .syncing(progress: 65, remaining: 1000),
        connectionStage: .syncing,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Connecting") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .connecting,
        connectionStage: .connecting,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Loading Blocks") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .connecting,
        connectionStage: .loadingBlocks(wallet: 2_100_000, daemon: 3_450_000),
        priceService: PriceService()
    )
    .padding()
}

#Preview("Error") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .error("Connection timeout"),
        connectionStage: .reachingNode,
        priceService: PriceService()
    )
    .padding()
}
