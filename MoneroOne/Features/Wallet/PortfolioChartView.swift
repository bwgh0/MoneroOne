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

    /// "3 transactions" on the chart, for its VoiceOver summary; nil for none.
    static func spokenCount(in points: [PortfolioDataPoint]) -> String? {
        let count = points.reduce(0) { $0 + $1.changes.count }
        switch count {
        case 0: return nil
        case 1: return "1 transaction"
        default: return "\(count) transactions"
        }
    }

    /// "Received 1.25 XMR", "Sent 0.5 XMR" or "3 transactions"; nil for none.
    static func summary(of changes: [BalanceChange]) -> String? {
        guard let first = changes.first else { return nil }
        guard changes.count == 1 else { return "\(changes.count) transactions" }
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
                accessibilityValue: "\(when.formatted(date: .abbreviated, time: .shortened)), portfolio \(formatValue(point.value))"
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
        var parts = ["\(changes.count) transactions"]
        if received > 0 { parts.append("received \(XMRFormatter.format(received)) XMR") }
        if sent > 0 { parts.append("sent \(XMRFormatter.format(sent)) XMR") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ type: MoneroTransaction.TransactionType, _ amount: Decimal) -> String {
        "\(type == .incoming ? "Received" : "Sent") \(XMRFormatter.format(amount)) XMR"
    }
}

/// The portfolio line and its dots, kept between renders. A scrub renders
/// the screen on every frame, and a busy wallet has hundreds of dot labels
/// to format; they are rebuilt only when an input changes.
final class PortfolioSeriesCache {
    private struct Inputs: Equatable {
        let prices: [PriceDataPoint]
        let rate: Double
        let ledger: BalanceLedger
        let startAtFirstHolding: Bool
        let currency: String
    }

    private var inputs: Inputs?
    private var points: [PortfolioDataPoint] = []
    private var markers: [ChartMarker] = []

    func series(
        prices: [PriceDataPoint],
        rate: Double,
        ledger: BalanceLedger,
        startAtFirstHolding: Bool = false,
        currency: String,
        formatValue: (Double) -> String
    ) -> (points: [PortfolioDataPoint], markers: [ChartMarker]) {
        let next = Inputs(prices: prices, rate: rate, ledger: ledger, startAtFirstHolding: startAtFirstHolding, currency: currency)
        if next != inputs {
            inputs = next
            points = PortfolioHistory.points(prices: prices, rate: rate, ledger: ledger, startAtFirstHolding: startAtFirstHolding)
            markers = PortfolioHistory.markers(for: points, formatValue: formatValue)
        }
        return (points, markers)
    }
}

struct PortfolioChartView: View {
    let balance: Decimal
    @ObservedObject var priceService: PriceService
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedPoint: PortfolioDataPoint?
    /// nil until the first load, which follows the first frame.
    @State private var ledger: BalanceLedger?
    @State private var seriesCache = PortfolioSeriesCache()

    enum TimeRange: String, CaseIterable {
        case day = "24H"
        case week = "1W"
        case month = "1M"
        case year = "1Y"
        case all = "All"

        var apiRange: String {
            switch self {
            case .day: return "1D"
            case .week: return "7D"
            case .month: return "1M"
            case .year: return "1Y"
            case .all: return "All"
            }
        }
    }

    private var balanceDouble: Double {
        (balance as NSDecimalNumber).doubleValue
    }

    private var currentPortfolioValue: Double? {
        guard let price = priceService.xmrPrice else { return nil }
        return balanceDouble * price
    }

    /// Portfolio value at every real price sample, in the selected currency
    /// (the API serves USD): the XMR held then times the price then, with
    /// a dot where transactions landed. Derived from the price series and
    /// the ledger so it cannot drift from them or the header. Empty until
    /// the ledger loads.
    private var series: (points: [PortfolioDataPoint], markers: [ChartMarker]) {
        guard let ledger else { return ([], []) }
        return seriesCache.series(
            prices: priceService.chartData,
            rate: priceService.usdToSelectedRate,
            ledger: ledger,
            startAtFirstHolding: selectedTimeRange == .all,
            currency: priceService.selectedCurrency,
            formatValue: formatCurrency
        )
    }

    private func portfolioRange(_ data: [PortfolioDataPoint]) -> (min: Double, max: Double)? {
        guard !data.isEmpty else { return nil }
        let values = data.map { $0.value }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    /// Changes whenever the balance or any transaction does, so the
    /// ledger reloads when a transaction arrives or confirms.
    private var ledgerKey: [String] {
        ["\(balance)"] + walletManager.transactions.map { "\($0.id) \($0.status)" }
    }

    var body: some View {
        // Read once per render; the header, chart and stats all use it.
        let series = self.series
        let data = series.points
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Portfolio Value Header
                    portfolioHeader(data)

                    // Time Range Selector
                    timeRangeSelector

                    // Chart
                    chartSection(data, markers: series.markers)

                    // Stats
                    statsSection(data)
                }
                .padding()
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                priceService.selectChartRange(selectedTimeRange.apiRange)
            }
            .task(id: ledgerKey) {
                // The newest transactions are in memory and draw at once;
                // the full list replaces them when it has loaded.
                if ledger == nil {
                    ledger = walletManager.recentBalanceLedger
                }
                let full = await walletManager.balanceLedger()
                if !Task.isCancelled {
                    ledger = full
                }
            }
            .onChange(of: selectedTimeRange) { newValue in
                selectedPoint = nil
                priceService.selectChartRange(newValue.apiRange)
            }
        }
    }

    // MARK: - Portfolio Header

    private var displayValue: Double? {
        selectedPoint?.value ?? currentPortfolioValue
    }

    /// Calculate percentage change based on portfolio data for selected time range
    private func portfolioValueChange(_ data: [PortfolioDataPoint]) -> Double? {
        guard data.count >= 2 else { return nil }
        guard let firstValue = data.first?.value,
              let lastValue = data.last?.value,
              firstValue > 0 else { return nil }
        return ((lastValue - firstValue) / firstValue) * 100
    }

    private func formatValueChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    private func portfolioHeader(_ data: [PortfolioDataPoint]) -> some View {
        VStack(spacing: 8) {
            if balanceDouble == 0 {
                // Zero balance state
                Text("Add XMR to track portfolio")
                    .font(.headline)
                    .foregroundColor(.secondary)
            } else if let value = displayValue {
                Text(formatCurrency(value))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: value)
                    .accessibilityLabel("Portfolio value, \(formatCurrency(value))")

                // One slot for both states so the chart never moves on scrub.
                ZStack {
                    // Show portfolio change for selected time range
                    HStack(spacing: 12) {
                        Text(XMRFormatter.format(balance) + " XMR")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let change = portfolioValueChange(data) {
                            HStack(spacing: 4) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(formatValueChange(change))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(change >= 0 ? .green : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                            .cornerRadius(6)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Change, \(timeAxis.spokenSpan)")
                            .accessibilityValue(ChartSpeech.spokenChange(change))
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.6)
                        }

                        // The change's label names the range.
                        Text(selectedTimeRange.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                    }
                    .opacity(selectedPoint == nil ? 1 : 0)
                    .accessibilityHidden(selectedPoint != nil)

                    if let selectedPoint = selectedPoint {
                        Text(scrubCaption(for: selectedPoint))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: selectedPoint == nil)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
            }
        }
        .padding(.vertical, 8)
    }

    private var timeAxis: ChartTimeAxis {
        ChartTimeAxis(rawValue: selectedTimeRange.apiRange) ?? .week
    }

    /// Ticks for the span on screen. "All" starts when the wallet first
    /// held XMR, so its span runs from weeks to years.
    private func tickAxis(for data: [PortfolioDataPoint]) -> ChartTimeAxis {
        guard selectedTimeRange == .all, let first = data.first, let last = data.last else { return timeAxis }
        return .fitting(span: last.timestamp.timeIntervalSince(first.timestamp))
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTimeRange = range
                    }
                } label: {
                    Text(range.rawValue)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(selectedTimeRange == range ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedTimeRange == range ?
                            Color.orange : Color.clear
                        )
                        .cornerRadius(8)
                }
                // "1 week", not "1W", and which one is on.
                .accessibilityLabel((ChartTimeAxis(rawValue: range.apiRange) ?? .week).spokenName)
                .accessibilityAddTraits(selectedTimeRange == range ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Chart Section

    private func chartSection(_ data: [PortfolioDataPoint], markers: [ChartMarker]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if (priceService.isLoadingChart || ledger == nil) && data.isEmpty {
                chartPlaceholder
            } else if data.isEmpty || balanceDouble == 0 {
                emptyChartState
            } else {
                SampledLineChart(
                    points: data,
                    domain: PriceService.chartYDomain(for: data.map { $0.value }),
                    timestamp: \.timestamp,
                    value: \.value,
                    axes: .init(time: tickAxis(for: data), currencyCode: priceService.selectedCurrency.uppercased()),
                    markers: markers,
                    speech: ChartSpeech(
                        title: "Portfolio",
                        span: timeAxis.spokenSpan,
                        currencyCode: priceService.selectedCurrency,
                        note: PortfolioHistory.spokenCount(in: data),
                        markerHint: "Moves between transactions"
                    ),
                    onSelect: { selectedPoint = $0 }
                )
                .equatable()
                .frame(height: 240)
            }
        }
        .frame(height: 280)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var chartPlaceholder: some View {
        VStack {
            ProgressView()
            Text("Loading chart data...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyChartState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            if balanceDouble == 0 {
                Text("Add XMR to see portfolio chart")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Unable to load chart")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats Section

    private func statsSection(_ data: [PortfolioDataPoint]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portfolio Range")
                    .font(.headline)
                Spacer()
            }

            if let range = portfolioRange(data), balanceDouble > 0 {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(
                        title: "\(selectedTimeRange.rawValue) High",
                        value: formatCurrency(range.max),
                        color: .green
                    )

                    StatCard(
                        title: "\(selectedTimeRange.rawValue) Low",
                        value: formatCurrency(range.min),
                        color: .red
                    )
                }
            } else {
                Text("No data available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.tertiarySystemGroupedBackground))
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Helpers

    /// Under the value while a sample is selected: the transactions that
    /// landed on it, or else the XMR held then, and when. A lone
    /// transaction gives its own time rather than the sample's.
    private func scrubCaption(for point: PortfolioDataPoint) -> String {
        let when = timeAxis.scrubLabel(for: point.changes.count == 1 ? point.changes[0].timestamp : point.timestamp)
        let what = PortfolioHistory.summary(of: point.changes) ?? "\(XMRFormatter.format(point.balance)) XMR"
        return "\(what) · \(when)"
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = FiatCurrency.formatter(for: priceService.selectedCurrency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

}

#Preview {
    PortfolioChartView(
        balance: 1.234567,
        priceService: PriceService()
    )
    .environmentObject(WalletManager())
}
