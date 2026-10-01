import SwiftUI
import Charts

struct PortfolioDataPoint: Identifiable, Equatable {
    var id: Double { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let value: Double
    /// XMR held at this sample.
    var balance: Decimal = 0
    /// Transactions this sample is the first to include, oldest first.
    var changes: [BalanceChange] = []
}

/// Portfolio value over time from real data only: at every price sample,
/// the XMR held at that moment times that sample's price. Nothing is
/// interpolated; a transaction between two samples shows as the straight
/// segment between them.
enum PortfolioHistory {
    /// `prices` is the drawn price series, oldest first, its last point
    /// being now. `rate` converts it to the display currency. With
    /// `startAtFirstHolding` ("All"), the years before the wallet first
    /// held anything are cut, keeping the one empty sample the line
    /// rises from.
    static func points(
        prices: [PriceDataPoint],
        rate: Double,
        ledger: BalanceLedger,
        startAtFirstHolding: Bool = false
    ) -> [PortfolioDataPoint] {
        var samples = prices
        if let knownSince = ledger.knownSince {
            // Before this the balance is unknown; draw nothing rather than a guess.
            samples.removeAll { $0.timestamp < knownSince }
        }
        guard let last = samples.indices.last else { return [] }

        // Walk back from the balance now. The last sample is now, so every
        // change after the sample before it shows there; each earlier
        // sample holds what was left before the changes after it.
        var held = [Decimal](repeating: 0, count: samples.count)
        var changes = [[BalanceChange]](repeating: [], count: samples.count)
        var running = ledger.balance
        var next = ledger.changes.count - 1
        held[last] = running
        for i in stride(from: last, to: 0, by: -1) {
            let previous = samples[i - 1].timestamp
            while next >= 0, ledger.changes[next].timestamp > previous {
                running -= ledger.changes[next].delta
                changes[i].append(ledger.changes[next])
                next -= 1
            }
            held[i - 1] = running
        }

        var start = 0
        if startAtFirstHolding, let first = held.firstIndex(where: { $0 > 0 }) {
            start = max(first - 1, 0)
        }
        return (start...last).map { i in
            // A ledger that does not add up can dip below zero; no one holds less than nothing.
            let balance = max(held[i], 0)
            let xmr = (balance as NSDecimalNumber).doubleValue
            return PortfolioDataPoint(
                timestamp: samples[i].timestamp,
                value: xmr * samples[i].price * rate,
                balance: balance,
                changes: changes[i].reversed()
            )
        }
    }

    /// The points `range` draws. A range that starts before All does would
    /// only add empty time before the wallet first held anything, so it
    /// shows exactly what All shows: All's window, drawn from All's samples
    /// (`allPrices`). A range that starts later keeps its own.
    static func points(
        for range: ChartTimeRange,
        prices: [PriceDataPoint],
        allPrices: [PriceDataPoint],
        rate: Double,
        ledger: BalanceLedger
    ) -> [PortfolioDataPoint] {
        guard range != .all else {
            return points(prices: prices, rate: rate, ledger: ledger, startAtFirstHolding: true)
        }
        let own = points(prices: prices, rate: rate, ledger: ledger)
        let all = points(prices: allPrices, rate: rate, ledger: ledger, startAtFirstHolding: true)
        if let start = own.first?.timestamp, let allStart = all.first?.timestamp, start < allStart {
            return all
        }
        return own
    }

    /// The final sample represents the current ledger, including changes since
    /// its price was fetched. It is Now, never a historical transaction cutoff.
    static func historicalSelection(
        _ point: PortfolioDataPoint?,
        in points: [PortfolioDataPoint]
    ) -> PortfolioDataPoint? {
        guard let point, point.timestamp != points.last?.timestamp else { return nil }
        return points.first { $0.timestamp == point.timestamp }
    }

    /// "3 transactions" on the chart, for its VoiceOver summary; nil for none.
    static func spokenCount(in points: [PortfolioDataPoint]) -> String? {
        let count = points.reduce(0) { $0 + $1.changes.count }
        switch count {
        case 0: return nil
        // Plural forms live in the string catalog ("1 transaction").
        default: return String(localized: "\(count) transactions")
        }
    }

    /// "Received 1.25 XMR", "Sent 0.5 XMR" or "3 transactions"; nil for none.
    static func summary(of changes: [BalanceChange]) -> String? {
        guard let first = changes.first else { return nil }
        guard changes.count == 1 else { return String(localized: "\(changes.count) transactions") }
        return describe(first.type, first.amount)
    }

    /// A dot on every sample that includes a transaction, green when the
    /// balance went up there. VoiceOver reads the amounts, when, and the
    /// portfolio value after.
    static func markers(for points: [PortfolioDataPoint], formatValue: (Double) -> String) -> [ChartMarker] {
        points.compactMap { point in
            guard let first = point.changes.first else { return nil }
            let net = point.changes.reduce(Decimal(0)) { $0 + $1.delta }
            let when = point.changes.count == 1 ? first.timestamp : point.timestamp
            return ChartMarker(
                timestamp: point.timestamp,
                value: point.value,
                style: net >= 0 ? .received : .sent,
                accessibilityLabel: spokenSummary(of: point.changes),
                accessibilityValue: String(localized: "\(when.formatted(date: .abbreviated, time: .shortened)), portfolio \(formatValue(point.value))", comment: "VoiceOver: date, then the portfolio value then")
            )
        }
    }

    /// Each amount when there are a few, the totals when there are many.
    private static func spokenSummary(of changes: [BalanceChange]) -> String {
        if changes.count <= 3 {
            return changes.map { describe($0.type, $0.amount) }.joined(separator: ", ")
        }
        let received = changes.filter { $0.type == .incoming }.reduce(Decimal(0)) { $0 + $1.amount }
        let sent = changes.filter { $0.type == .outgoing }.reduce(Decimal(0)) { $0 + $1.amount }
        var parts = [String(localized: "\(changes.count) transactions")]
        if received > 0 { parts.append(String(localized: "received \(XMRFormatter.format(received)) XMR", comment: "VoiceOver: total received")) }
        if sent > 0 { parts.append(String(localized: "sent \(XMRFormatter.format(sent)) XMR", comment: "VoiceOver: total sent")) }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ type: MoneroTransaction.TransactionType, _ amount: Decimal) -> String {
        type == .incoming
            ? String(localized: "Received \(XMRFormatter.format(amount)) XMR")
            : String(localized: "Sent \(XMRFormatter.format(amount)) XMR")
    }
}

// MARK: - Balance history in the wallet card

private struct HistoryDisclosureKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    /// Marks the History open and close animation. Views that otherwise
    /// drop animations, such as the activity list, keep this one so they
    /// move with the card instead of jumping ahead of it.
    var isHistoryDisclosure: Bool {
        get { self[HistoryDisclosureKey.self] }
        set { self[HistoryDisclosureKey.self] = newValue }
    }
}

/// The balance card's history, owned by the screen that shows the card so
/// it outlives History closing and reopening. The ledger loads while
/// History is open and reloads after a transaction or the balance changes.
/// Each range's series is built off the main thread and kept; while a range
/// loads, the last series stays up, so the chart is never torn down.
@Observable
final class BalanceHistoryModel {
    struct Series: Equatable {
        let range: ChartTimeRange
        let currency: String
        let points: [PortfolioDataPoint]
        let markers: [ChartMarker]
        let domain: ClosedRange<Double>
        /// Ticks for the span drawn; "All" starts at the first holding.
        let tickAxis: ChartTimeAxis
        let spokenCount: String?
        /// Two samples or more, one of them holding XMR.
        let isDrawable: Bool
    }

    /// Everything a series is built from.
    private struct Inputs: Equatable {
        let range: ChartTimeRange
        let prices: [PriceDataPoint]
        /// All's samples, which a range that starts before All draws.
        let allPrices: [PriceDataPoint]
        let rate: Double
        let currency: String
        let ledger: BalanceLedger
    }

    /// The wallet's full history once loaded; its newest transactions before.
    private(set) var ledger: BalanceLedger?
    /// Where the history starts when the wallet holds only part of it,
    /// else nil. Read from the full list only, so a long history that is
    /// still loading does not flash the note under the chart.
    private(set) var historyStart: Date?
    /// Bumped with `ledger`, a cheap signal to rebuild the series.
    private(set) var ledgerVersion = 0
    /// What the chart draws. It belongs to the previous range until the
    /// selected one is built.
    private(set) var shown: Series?
    /// Ranges whose price fetch has finished once, with or without data.
    private(set) var fetchedRanges: Set<ChartTimeRange> = []
    /// The chart's cursor, mirroring the selected point.
    let cursor = ChartCursor()

    @ObservationIgnored private var built: [ChartTimeRange: (inputs: Inputs, series: Series)] = [:]
    @ObservationIgnored private var wantedRange: ChartTimeRange?
    @ObservationIgnored private var ledgerIsStale = true
    @ObservationIgnored private var ledgerTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    deinit {
        ledgerTask?.cancel()
        buildTask?.cancel()
    }

    /// A transaction or the balance changed; the next refresh reloads.
    func invalidateLedger() {
        ledgerIsStale = true
    }

    /// Loads the ledger when it is missing or out of date. The newest
    /// transactions are in memory and draw at once; the full list
    /// replaces them when it has loaded.
    @MainActor
    func refreshLedger(from walletManager: WalletManager) {
        guard ledgerIsStale else { return }
        ledgerIsStale = false
        let session = walletManager.walletSessionId
        if ledger == nil {
            apply(walletManager.recentBalanceLedger)
        }
        ledgerTask?.cancel()
        ledgerTask = Task { @MainActor [weak self] in
            let full = await walletManager.balanceLedger()
            // A wallet switch while loading: the list belongs to the old one.
            guard let self, !Task.isCancelled, session == walletManager.walletSessionId else { return }
            self.apply(full)
            if self.historyStart != full.knownSince {
                self.historyStart = full.knownSince
            }
        }
    }

    func markFetched(_ range: ChartTimeRange) {
        if !fetchedRanges.contains(range) {
            fetchedRanges.insert(range)
        }
    }

    /// Shows `range`: its kept series when no input changed, else a new one
    /// built off the main thread. Until then the current series stays up.
    /// It waits for All's samples too, as a range that starts before All
    /// draws those.
    @MainActor
    func show(
        _ range: ChartTimeRange,
        prices: [PriceDataPoint],
        pricesLoaded: Bool,
        allPrices: [PriceDataPoint],
        allPricesLoaded: Bool,
        rate: Double,
        currency: String
    ) {
        wantedRange = range
        guard let ledger, pricesLoaded, allPricesLoaded else { return }
        let inputs = Inputs(range: range, prices: prices, allPrices: allPrices, rate: rate, currency: currency, ledger: ledger)
        buildTask?.cancel()
        if let kept = built[range], kept.inputs == inputs {
            display(kept.series)
            return
        }
        buildTask = Task { @MainActor [weak self] in
            let series = await Task.detached(priority: .userInitiated) {
                Self.makeSeries(inputs)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.built[range] = (inputs, series)
            if self.wantedRange == range {
                self.display(series)
            }
        }
    }

    private func apply(_ next: BalanceLedger) {
        guard next != ledger else { return }
        ledger = next
        ledgerVersion &+= 1
        // Every kept series was drawn from the old ledger.
        built.removeAll()
    }

    private func display(_ series: Series) {
        if series != shown {
            shown = series
        }
    }

    /// The line, its dots and its axis for one range. Pure, so it can run
    /// off the main thread; formats with its own currency formatter.
    private static func makeSeries(_ inputs: Inputs) -> Series {
        let points = PortfolioHistory.points(
            for: inputs.range,
            prices: inputs.prices,
            allPrices: inputs.allPrices,
            rate: inputs.rate,
            ledger: inputs.ledger
        )
        let formatter = FiatCurrency.formatter(for: inputs.currency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let markers = PortfolioHistory.markers(for: points) { value in
            formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        let tickAxis: ChartTimeAxis
        if let first = points.first, let last = points.last {
            tickAxis = .fitting(span: last.timestamp.timeIntervalSince(first.timestamp))
        } else {
            tickAxis = ChartTimeAxis(rawValue: inputs.range.apiRange) ?? .week
        }
        return Series(
            range: inputs.range,
            currency: inputs.currency,
            points: points,
            markers: markers,
            domain: PriceService.chartYDomain(for: points.map(\.value)),
            tickAxis: tickAxis,
            spokenCount: PortfolioHistory.spokenCount(in: points),
            isDrawable: points.count >= 2 && points.contains { $0.balance > 0 }
        )
    }
}

/// Optional detail inside the wallet's existing balance card. The parent owns
/// the one displayed balance and the activity cutoff through selectedPoint.
/// Every row keeps one height in every range and state (loading, empty,
/// scrubbing), so the card never jumps; the chart stays built between
/// ranges and while History is closed.
struct BalanceHistoryChart: View {
    let balance: Decimal
    /// False while History is closed: the chart stays built but idle.
    let isActive: Bool
    let model: BalanceHistoryModel
    @ObservedObject var priceService: PriceService
    @EnvironmentObject private var walletManager: WalletManager
    @Binding var selectedTimeRange: ChartTimeRange
    @Binding var selectedPoint: PortfolioDataPoint?
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 152

    /// Drawn, hidden, before the first series is built.
    private static let placeholder = BalanceHistoryModel.Series(
        range: .week, currency: "usd", points: [], markers: [], domain: 0...1,
        tickAxis: .week, spokenCount: nil, isDrawable: false
    )

    /// Changes whenever the selected range's series needs a rebuild.
    private struct SeriesKey: Equatable {
        let range: ChartTimeRange
        let sampleCount: Int
        let firstSample: Date?
        let lastSample: Date?
        let tip: Double?
        let tipAt: Date?
        let rate: Double
        let currency: String
        let ledgerVersion: Int
        let fetched: Bool
        let allSampleCount: Int
        let allFirstSample: Date?
        let allLastSample: Date?
        let allFetched: Bool
        let isActive: Bool
    }

    private var seriesKey: SeriesKey {
        let samples = priceService.chartDataCache[selectedTimeRange.apiRange]
        let allSamples = priceService.chartDataCache[ChartTimeRange.all.apiRange]
        return SeriesKey(
            range: selectedTimeRange,
            sampleCount: samples?.count ?? 0,
            firstSample: samples?.first?.timestamp,
            lastSample: samples?.last?.timestamp,
            tip: priceService.xmrPrice,
            tipAt: priceService.lastUpdated,
            rate: priceService.usdToSelectedRate,
            currency: priceService.selectedCurrency,
            ledgerVersion: model.ledgerVersion,
            fetched: model.fetchedRanges.contains(selectedTimeRange),
            allSampleCount: allSamples?.count ?? 0,
            allFirstSample: allSamples?.first?.timestamp,
            allLastSample: allSamples?.last?.timestamp,
            allFetched: model.fetchedRanges.contains(.all),
            isActive: isActive
        )
    }

    private var timeAxis: ChartTimeAxis {
        ChartTimeAxis(rawValue: selectedTimeRange.apiRange) ?? .week
    }

    var body: some View {
        let shown = model.shown
        let isCurrent = shown?.range == selectedTimeRange
        VStack(spacing: 12) {
            header

            ZStack {
                chart(shown ?? Self.placeholder, isLive: isCurrent && shown?.isDrawable == true)
                chartOverlay(shown, isCurrent: isCurrent)
            }
            .frame(height: chartHeight)

            GlassSegmentedPicker(selection: $selectedTimeRange, accessibilityLabel: { range in
                (ChartTimeAxis(rawValue: range.apiRange) ?? .week).spokenName
            }) { $0.title }

            coverageNote
        }
        .task(id: isActive ? selectedTimeRange : nil) {
            guard isActive else { return }
            let range = selectedTimeRange
            // A range that starts before All draws All's samples, so All loads too.
            async let own: Void = priceService.fetchChartData(range: range.apiRange)
            if range != .all {
                await priceService.fetchChartData(range: ChartTimeRange.all.apiRange)
                if !Task.isCancelled {
                    model.markFetched(.all)
                }
            }
            await own
            if !Task.isCancelled {
                model.markFetched(range)
            }
        }
        .onChange(of: seriesKey, initial: true) { _, key in
            guard key.isActive else { return }
            model.show(
                key.range,
                prices: priceService.chartData(for: key.range.apiRange),
                pricesLoaded: key.sampleCount > 0 || key.fetched,
                allPrices: priceService.chartData(for: ChartTimeRange.all.apiRange),
                allPricesLoaded: key.allSampleCount > 0 || key.allFetched,
                rate: key.rate,
                currency: key.currency
            )
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active { model.refreshLedger(from: walletManager) }
        }
        .onChange(of: walletManager.transactions) { _, _ in ledgerChanged() }
        .onChange(of: balance) { _, _ in ledgerChanged() }
        .onChange(of: selectedTimeRange) { _, _ in selectedPoint = nil }
        .onChange(of: shown) { _, series in
            // A refresh keeps the same instant when its real sample survives.
            // The replacement ledger may change its holdings or currency value.
            guard let series, series.range == selectedTimeRange else { return }
            selectedPoint = PortfolioHistory.historicalSelection(selectedPoint, in: series.points)
        }
        .onChange(of: selectedPoint?.timestamp, initial: true) { _, timestamp in
            model.cursor.timestamp = timestamp
        }
    }

    private func ledgerChanged() {
        model.invalidateLedger()
        if isActive {
            model.refreshLedger(from: walletManager)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(selectedPoint.map { $0.timestamp.formatted(date: .abbreviated, time: .shortened) }
                 ?? timeAxis.spokenSpan.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("wallet.historyDate")
            Spacer(minLength: 4)
            if selectedPoint != nil {
                Button {
                    selectedPoint = nil
                    HapticFeedback.shared.buttonPress()
                } label: {
                    Label("Now", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to current balance and activity")
                .accessibilityIdentifier("wallet.historyNow")
            } else {
                Text(priceService.selectedCurrency.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
    }

    /// Always in the hierarchy: loading, empty and range changes fade it
    /// rather than swap it out, so Swift Charts never rebuilds from nothing.
    private func chart(_ series: BalanceHistoryModel.Series, isLive: Bool) -> some View {
        SampledLineChart(
            points: series.points,
            domain: series.domain,
            timestamp: \.timestamp,
            value: \.value,
            axes: .init(time: series.tickAxis, currencyCode: series.currency.uppercased()),
            markers: series.markers,
            insetsForMarkers: true,
            speech: ChartSpeech(
                title: String(localized: "Balance history"),
                span: (ChartTimeAxis(rawValue: series.range.apiRange) ?? .week).spokenSpan,
                currencyCode: series.currency,
                note: series.spokenCount,
                markerHint: String(localized: "Adjust to explore the balance and activity at each time. Return to Now to show the current wallet.")
            ),
            cursor: model.cursor,
            onSelect: { selectedPoint = PortfolioHistory.historicalSelection($0, in: series.points) }
        )
        .equatable()
        // New data replaces the line in one frame; morphing hundreds of
        // samples inside another animation is what stutters.
        .transaction { $0.animation = nil }
        .animation(.easeInOut(duration: 0.2)) { content in
            content.opacity(isLive ? 1 : (series.isDrawable ? 0.3 : 0))
        }
        .allowsHitTesting(isLive)
        .accessibilityHidden(!isLive)
        .accessibilityIdentifier("wallet.historyChart")
    }

    @ViewBuilder
    private func chartOverlay(_ series: BalanceHistoryModel.Series?, isCurrent: Bool) -> some View {
        if series == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading balance history…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isCurrent {
            ProgressView()
                .accessibilityLabel(Text("Loading balance history…"))
        } else if series?.isDrawable == false {
            VStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(isNewWallet ? "Your history starts here" : "History unavailable for this period")
                    .font(.subheadline.weight(.medium))
                Text(isNewWallet ? "Receive XMR to start tracking your wallet’s value." : "Try another time range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isNewWallet: Bool {
        balance == 0 && model.ledger?.changes.isEmpty == true
    }

    /// Says where the history starts when the wallet holds only part of
    /// it. That is per wallet, so every range keeps the same height.
    @ViewBuilder
    private var coverageNote: some View {
        if let historyStart = model.historyStart {
            Text("History available from \(historyStart.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
    }
}
