import SwiftUI
import Charts
import Accessibility

struct PriceChartView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceAlertService: PriceAlertService
    @State private var selectedTimeRange: TimeRange = .week
    /// The sample under the finger, in the selected currency.
    @State private var selectedPoint: PriceDataPoint?

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

        /// The button label, in the user's language ("1W").
        var title: String { ChartRangeTitle.title(for: rawValue) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Current Price Header
                    priceHeader

                    // Time Range Selector
                    timeRangeSelector

                    // Price Chart
                    chartSection

                    // Price Statistics
                    statsSection
                }
                .padding()
            }
            .navigationTitle("Monero Price")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                priceService.selectChartRange(selectedTimeRange.apiRange)
            }
            .onChange(of: selectedTimeRange) { newValue in
                selectedPoint = nil
                priceService.selectChartRange(newValue.apiRange)
            }
            .refreshable {
                await priceService.fetchPrice()
                await priceService.fetchChartData(range: selectedTimeRange.apiRange, force: true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        PriceAlertsView(
                            priceAlertService: priceAlertService,
                            priceService: priceService
                        )
                    } label: {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("Price alerts")
                    .accessibilityHint("View and manage price alerts")
                }
            }
        }
    }

    // MARK: - Price Header

    private var displayPrice: Double? {
        selectedPoint?.price ?? priceService.xmrPrice
    }

    /// Every real sample, converted to the selected currency (the API serves USD).
    private var displayPoints: [PriceDataPoint] {
        let rate = priceService.usdToSelectedRate
        return priceService.chartData.map { PriceDataPoint(timestamp: $0.timestamp, price: $0.price * rate) }
    }

    /// Calculate percentage change based on chart data for selected time range
    private var chartPriceChange: Double? {
        guard priceService.chartData.count >= 2 else { return nil }
        guard let firstPrice = priceService.chartData.first?.price,
              let lastPrice = priceService.chartData.last?.price,
              firstPrice > 0 else { return nil }
        return ((lastPrice - firstPrice) / firstPrice) * 100
    }

    private func formatChartPriceChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    private var priceHeader: some View {
        VStack(spacing: 8) {
            if let price = displayPrice {
                Text(formatPrice(price))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: price)
                    .accessibilityLabel("Current Monero price, \(formatPrice(price))")

                // Both states share one slot so the chart below never moves
                // when a scrub starts or ends.
                ZStack {
                    // Show price change for selected time range
                    HStack(spacing: 16) {
                        if let change = chartPriceChange {
                            HStack(spacing: 4) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(formatChartPriceChange(change))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(change >= 0 ? .green : .red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                            .cornerRadius(8)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Price change \(selectedTimeRange.title), \(change >= 0 ? String(localized: "up", comment: "Price went up") : String(localized: "down", comment: "Price went down")) \(formatChartPriceChange(change))")
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        Text(selectedTimeRange.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(selectedPoint == nil ? 1 : 0)
                    .accessibilityHidden(selectedPoint != nil)

                    if let selectedPoint = selectedPoint {
                        // Show selected date when interacting
                        Text(timeAxis.scrubLabel(for: selectedPoint.timestamp))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
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

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        GlassSegmentedPicker(selection: $selectedTimeRange) { range in
            range.title
        }
    }

    // MARK: - Chart Section

    /// Derived from the drawn series on every read, so the live tip and a
    /// currency change can never push the line outside the axis.
    private var chartYDomain: ClosedRange<Double> {
        PriceService.chartYDomain(for: displayPoints.map { $0.price })
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && priceService.chartData.isEmpty {
                chartPlaceholder
            } else if priceService.chartData.isEmpty {
                emptyChartState
            } else {
                SampledLineChart(
                    points: displayPoints,
                    domain: chartYDomain,
                    timestamp: \.timestamp,
                    value: \.price,
                    axes: .init(time: timeAxis, currencyCode: priceService.selectedCurrency.uppercased()),
                    speech: ChartSpeech(title: String(localized: "Monero price"), span: timeAxis.spokenSpan, currencyCode: priceService.selectedCurrency),
                    onSelect: { selectedPoint = $0 }
                )
                .equatable()
                .frame(height: 240)
                .clipped()
            }
        }
        .frame(height: 280)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
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
            Text("Unable to load chart")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Statistics")
                    .font(.headline)
                Spacer()
            }

            if let range = priceService.priceRange {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(
                        title: String(localized: "\(selectedTimeRange.title) High", comment: "Highest price in the chart range, e.g. 1W High"),
                        value: formatPrice(range.max),
                        color: .green
                    )

                    StatCard(
                        title: String(localized: "\(selectedTimeRange.title) Low", comment: "Lowest price in the chart range, e.g. 1W Low"),
                        value: formatPrice(range.min),
                        color: .red
                    )
                }
            }

            if let lastUpdated = priceService.lastUpdated {
                Text("Last updated \(lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatPrice(_ price: Double) -> String {
        let formatter = FiatCurrency.formatter(for: priceService.selectedCurrency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: price)) ?? "\(price)"
    }
}

// MARK: - Range titles

/// Chart range button labels, shared by the price, portfolio and dashboard
/// charts. The raw values ("1W") stay the API and cache keys.
enum ChartRangeTitle {
    static func title(for rawValue: String) -> String {
        switch rawValue {
        case "24H": return String(localized: "24H", comment: "Chart range button: 24 hours")
        case "1W": return String(localized: "1W", comment: "Chart range button: 1 week")
        case "1M": return String(localized: "1M", comment: "Chart range button: 1 month")
        case "1Y": return String(localized: "1Y", comment: "Chart range button: 1 year")
        case "All": return String(localized: "All", comment: "Chart range button: all time")
        default: return rawValue
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

// MARK: - Chart time axis

/// How a range labels time. Ticks land on calendar landmarks (midnight,
/// the 1st, January 1st, a quarter of the day), not at "N hours before
/// now", so the axis reads the same way every time it is opened. Also
/// owns the scrub label, which names the day whenever the range makes a
/// bare time ambiguous.
enum ChartTimeAxis: String, Equatable {
    case day = "1D"
    case week = "7D"
    case month = "1M"
    case year = "1Y"
    case all = "All"

    /// Tick dates inside `span`, on this range's landmarks.
    func ticks(in span: ClosedRange<Date>, calendar: Calendar = .current) -> [Date] {
        if self == .day {
            return dayTicks(in: span, calendar: calendar)
        }
        let step = step(across: span)
        var ticks: [Date] = []
        var tick = firstTick(atOrAfter: span.lowerBound, calendar: calendar)
        while tick <= span.upperBound, ticks.count < 64 {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: step.component, value: step.count, to: tick) else { break }
            tick = next
        }
        return ticks
    }

    /// The range whose ticks suit a span this long. The portfolio's "All"
    /// starts when the wallet first held XMR, weeks or years ago.
    static func fitting(span: TimeInterval) -> ChartTimeAxis {
        let day: TimeInterval = 24 * 60 * 60
        switch span {
        case ..<(2 * day): return .day
        case ..<(10 * day): return .week
        case ..<(60 * day): return .month
        // Month names repeat past a year, so longer spans label years.
        case ..<(400 * day): return .year
        default: return .all
        }
    }

    /// Axis label for a tick.
    func tickLabel(for date: Date) -> String {
        switch self {
        case .day: return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))  // "5 AM"; 24h locales "05"
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))      // "Wed"
        case .month: return date.formatted(.dateTime.month(.abbreviated).day()) // "Sep 15"
        case .year: return date.formatted(.dateTime.month(.abbreviated))        // "Nov"
        case .all: return date.formatted(.dateTime.year())                      // "2022"
        }
    }

    /// The range as VoiceOver says it on a range button: "1 week".
    var spokenName: String {
        switch self {
        case .day: return String(localized: "24 hours", comment: "VoiceOver: chart range button")
        case .week: return String(localized: "1 week", comment: "VoiceOver: chart range button")
        case .month: return String(localized: "1 month", comment: "VoiceOver: chart range button")
        case .year: return String(localized: "1 year", comment: "VoiceOver: chart range button")
        case .all: return String(localized: "All time", comment: "VoiceOver: chart range button")
        }
    }

    /// The time a chart on this range covers, as VoiceOver says it: "past week".
    var spokenSpan: String {
        switch self {
        case .day: return String(localized: "past 24 hours", comment: "VoiceOver: time a chart covers")
        case .week: return String(localized: "past week", comment: "VoiceOver: time a chart covers")
        case .month: return String(localized: "past month", comment: "VoiceOver: time a chart covers")
        case .year: return String(localized: "past year", comment: "VoiceOver: time a chart covers")
        case .all: return String(localized: "all time", comment: "VoiceOver: time a chart covers")
        }
    }

    /// Label for the sample under the finger.
    func scrubLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .day:
            if calendar.isDate(date, inSameDayAs: now) {
                return date.formatted(date: .omitted, time: .shortened)
            }
            // "Yesterday at 3:05 PM", localized by the system.
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        case .week:
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        case .month:
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        case .year, .all:
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    /// 24h tick hours. Five-hour steps on purpose: a 12-hour clock repeats
    /// its numerals for any step that divides 12 (4 PM, 8 PM, 12 AM, 4 AM,
    /// 8 AM, 12 PM reads as "4 8 12 4 8 12"). Five gives 12 AM, 5 AM, 10 AM,
    /// 3 PM, 8 PM: every numeral in a day distinct. Restarts at midnight.
    static let dayTickHours = [0, 5, 10, 15, 20]

    private func dayTicks(in span: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        var ticks: [Date] = []
        var day = calendar.startOfDay(for: span.lowerBound)
        while day <= span.upperBound, ticks.count < 64 {
            for hour in Self.dayTickHours {
                guard let tick = calendar.date(byAdding: .hour, value: hour, to: day) else { continue }
                if span.contains(tick) { ticks.append(tick) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks
    }

    private func step(across span: ClosedRange<Date>) -> (component: Calendar.Component, count: Int) {
        switch self {
        case .day: return (.hour, 5)  // unused: `dayTicks` restarts at midnight
        case .week: return (.day, 1)
        case .month: return (.day, 7)
        case .year: return (.month, 2)
        case .all:
            // Every other year across the price history since 2014; every
            // year for a shorter span, so it still gets a few labels.
            let years = span.upperBound.timeIntervalSince(span.lowerBound) / (365 * 24 * 60 * 60)
            return (.year, years < 6 ? 1 : 2)
        }
    }

    /// The first landmark at or after `date`.
    private func firstTick(atOrAfter date: Date, calendar: Calendar) -> Date {
        switch self {
        case .day:
            return date  // handled by `dayTicks`
        case .week:
            let start = calendar.startOfDay(for: date)
            return start == date ? start : calendar.date(byAdding: .day, value: 1, to: start) ?? date
        case .month:
            // Week starts, so the labels are the same weekday all the way across.
            let interval = calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 0)
            return interval.start == date ? date : interval.end
        case .year:
            let interval = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
            return interval.start == date ? date : interval.end
        case .all:
            let interval = calendar.dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 0)
            return interval.start == date ? date : interval.end
        }
    }
}

// MARK: - Sampled line chart

/// One series drawn as a line and fill over every real sample, with a
/// touch-and-drag scrub overlay. The chart holds no binding: the selection
/// is state inside the overlay and is reported up through `onSelect`, so a
/// scrub re-renders the overlay only and never the marks. Callers apply
/// `.equatable()`; the marks then rebuild only when `points`, `domain` or
/// `axes` change. That is what keeps 700 samples smooth; the old code hid
/// the cost by drawing 96 of them.
///
/// VoiceOver sees the chart as one element (see `ChartSpeech`); the marks
/// are hidden, or Swift Charts adds a stop for every day of the range.
struct SampledLineChart<Point: Identifiable & Equatable>: View, Equatable {
    struct Axes: Equatable {
        var time: ChartTimeAxis
        var currencyCode: String
    }

    let points: [Point]
    let domain: ClosedRange<Double>
    let timestamp: KeyPath<Point, Date>
    let value: KeyPath<Point, Double>
    /// nil hides both axes (dashboard card).
    let axes: Axes?
    /// Dots drawn on top of the line.
    var markers: [ChartMarker] = []
    let speech: ChartSpeech
    let onSelect: (Point?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.domain == rhs.domain && lhs.axes == rhs.axes
            && lhs.timestamp == rhs.timestamp && lhs.value == rhs.value
            && lhs.markers == rhs.markers && lhs.speech == rhs.speech
    }

    private static var fill: LinearGradient {
        LinearGradient(
            colors: [Color.orange.opacity(0.4), Color.orange.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        if let axes {
            chart
                .chartXAxis {
                    AxisMarks(values: xTicks(for: axes.time)) { mark in
                        AxisGridLine()
                        AxisValueLabel(collisionResolution: .greedy) {
                            if let date = mark.as(Date.self) {
                                Text(axes.time.tickLabel(for: date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { mark in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = mark.as(Double.self) {
                                Text(Self.compact(amount, currencyCode: axes.currencyCode, span: domain.upperBound - domain.lowerBound))
                                    .font(.caption2)
                            }
                        }
                    }
                }
        } else {
            chart
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point[keyPath: timestamp]),
                    yStart: .value("Min", domain.lowerBound),
                    yEnd: .value("Value", point[keyPath: value])
                )
                .foregroundStyle(Self.fill)
                .interpolationMethod(.linear)
                .accessibilityHidden(true)

                LineMark(
                    x: .value("Time", point[keyPath: timestamp]),
                    y: .value("Value", point[keyPath: value])
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                .accessibilityHidden(true)
            }

            ForEach(markers) { marker in
                PointMark(
                    x: .value("Time", marker.timestamp),
                    y: .value("Value", marker.value)
                )
                .symbol {
                    ChartMarkerBadge(style: marker.style)
                }
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: domain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ScrubOverlay(
                    proxy: proxy,
                    plotFrame: Self.plotFrame(proxy, in: geometry),
                    points: points,
                    markers: markers,
                    timestamp: timestamp,
                    value: value,
                    speech: speech,
                    summary: summary,
                    audioGraph: audioGraph,
                    onSelect: onSelect
                )
            }
        }
    }

    /// "From $504.46 to $550.29, up 8.99%": the first and last sample.
    private var summary: String {
        guard let first = points.first?[keyPath: value], let last = points.last?[keyPath: value] else { return "" }
        return speech.summary(first: first, last: last)
    }

    private var audioGraph: ChartAudioGraph {
        ChartAudioGraph(
            speech: speech,
            summary: summary,
            samples: points.map { ChartAudioGraph.Sample(date: $0[keyPath: timestamp], value: $0[keyPath: value]) },
            markers: markers,
            domain: domain
        )
    }

    private static func plotFrame(_ proxy: ChartProxy, in geometry: GeometryProxy) -> CGRect {
        if let anchor = proxy.plotFrame {
            return geometry[anchor]
        }
        return CGRect(origin: .zero, size: geometry.size)
    }

    private func xTicks(for time: ChartTimeAxis) -> [Date] {
        guard let first = points.first?[keyPath: timestamp], let last = points.last?[keyPath: timestamp],
              first <= last else { return [] }
        return time.ticks(in: first...last)
    }

    /// Axis amount with as many decimals as the axis span needs: none for
    /// a $400 span, two for a portfolio that moved 80 cents.
    private static func compact(_ amount: Double, currencyCode: String, span: Double) -> String {
        let formatter = FiatCurrency.formatter(for: currencyCode)
        formatter.maximumFractionDigits = span < 5 ? 2 : 0
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
    }
}

/// A badge on a real sample of the line that stands for an event, such as
/// a transaction on the portfolio chart.
struct ChartMarker: Identifiable, Equatable {
    /// Colors and arrows follow the activity rows: green in, orange out.
    enum Style: Equatable {
        case received
        case sent
    }

    var id: Date { timestamp }
    let timestamp: Date
    let value: Double
    let style: Style
    let accessibilityLabel: String
    let accessibilityValue: String
}

/// What VoiceOver says for a chart. The chart is one element: the label
/// names it, the value sums the line up, the rotor offers an Audio Graph
/// of every sample, and when the chart has markers a swipe up or down
/// steps through them.
struct ChartSpeech: Equatable {
    /// "Portfolio", "Monero price".
    var title: String
    /// `ChartTimeAxis.spokenSpan`: "past week".
    var span: String
    /// The currency of the values.
    var currencyCode: String
    /// Said after the numbers: "3 transactions".
    var note: String? = nil
    /// What a swipe up or down does when the chart has markers.
    var markerHint: String? = nil

    /// "Portfolio chart, past week".
    var label: String { String(localized: "\(title) chart, \(span)", comment: "VoiceOver: chart name, then the time it covers") }

    /// A value on the line: "$1,234.56".
    func format(_ amount: Double) -> String {
        let formatter = FiatCurrency.formatter(for: currencyCode)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    /// "From $504.46 to $550.29, up 8.99%, 3 transactions". No change is
    /// given from zero, as the headers give none.
    func summary(first: Double, last: Double) -> String {
        var parts = [String(localized: "From \(format(first)) to \(format(last))", comment: "VoiceOver: first and last value on a chart")]
        if first > 0 {
            parts.append(Self.spokenChange((last - first) / first * 100))
        }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    /// A percent change as the headers round it: "up 8.99%", "down 1.20%",
    /// "unchanged".
    static func spokenChange(_ percent: Double) -> String {
        let size = String(format: "%.2f", abs(percent))
        if size == "0.00" { return String(localized: "unchanged", comment: "VoiceOver: no price change") }
        return percent > 0
            ? String(localized: "up \(size)%", comment: "VoiceOver: percent change")
            : String(localized: "down \(size)%", comment: "VoiceOver: percent change")
    }
}

/// Every sample as an Audio Graph (VoiceOver rotor, Audio Graph): time
/// across, value up. A sample with a marker carries the marker's words.
struct ChartAudioGraph: AXChartDescriptorRepresentable {
    struct Sample {
        let date: Date
        let value: Double
    }

    let speech: ChartSpeech
    let summary: String
    let samples: [Sample]
    let markers: [ChartMarker]
    let domain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = Dictionary(markers.map { ($0.timestamp, $0.accessibilityLabel) }) { first, _ in first }
        let start = samples.first?.date.timeIntervalSince1970 ?? 0
        let end = max(samples.last?.date.timeIntervalSince1970 ?? 0, start)
        let time = AXNumericDataAxisDescriptor(title: String(localized: "Time", comment: "Audio Graph axis"), range: start...end, gridlinePositions: []) { seconds in
            Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
        }
        let value = AXNumericDataAxisDescriptor(title: String(localized: "Value", comment: "Audio Graph axis"), range: domain, gridlinePositions: [], valueDescriptionProvider: speech.format)
        let series = AXDataSeriesDescriptor(
            name: speech.title,
            isContinuous: true,
            dataPoints: samples.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value, label: labels[$0.date]) }
        )
        return AXChartDescriptor(title: speech.label, summary: summary, xAxis: time, yAxis: value, series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = makeChartDescriptor()
        descriptor.title = fresh.title
        descriptor.summary = fresh.summary
        descriptor.xAxis = fresh.xAxis
        descriptor.yAxis = fresh.yAxis
        descriptor.series = fresh.series
    }
}

/// A disc in the activity row's color with its arrow. A ring in the
/// card's color cuts it out of the line under it. Selected, it grows and
/// sits in a halo.
private struct ChartMarkerBadge: View {
    let style: ChartMarker.Style
    var selected = false

    private var tint: Color { style == .received ? .green : .orange }

    var body: some View {
        Image(systemName: style == .received ? "arrow.down.left" : "arrow.up.right")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(tint))
            .padding(2)
            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            .scaleEffect(selected ? 1.25 : 1)
            .background {
                if selected {
                    Circle().fill(tint.opacity(0.15)).frame(width: 38, height: 38)
                }
            }
    }
}

/// Touch or drag to read a sample; releasing clears it. Tapping a marker
/// keeps its sample selected until the next tap, so the caller can show
/// it up top; tapping it again or anywhere else clears it. The gesture
/// runs alongside the page's scroll view. The first clear move of a touch
/// decides its axis once: mostly vertical means the page is scrolling and
/// the touch is ignored until it ends; anything else scrubs.
///
/// The overlay is also the chart's one VoiceOver element. A swipe up or
/// down pins the next or previous marker, as a tap on it would, so the
/// header shows it too; moving VoiceOver off the chart clears it.
private struct ScrubOverlay<Point: Identifiable & Equatable>: View {
    let proxy: ChartProxy
    let plotFrame: CGRect
    let points: [Point]
    let markers: [ChartMarker]
    let timestamp: KeyPath<Point, Date>
    let value: KeyPath<Point, Double>
    let speech: ChartSpeech
    let summary: String
    let audioGraph: ChartAudioGraph
    let onSelect: (Point?) -> Void

    @State private var selected: Point?
    @State private var scrolling = false
    /// The marker a tap or a VoiceOver swipe left selected.
    @State private var pinned: ChartMarker?
    /// What was pinned when the current touch began, so tapping it again clears it.
    @State private var pinnedAtTouchStart: ChartMarker?
    @State private var touching = false
    @AccessibilityFocusState private var voiceOverFocus: Bool

    /// Half of the 44 pt minimum hit target.
    private static var markerHitRadius: CGFloat { 22 }

    var body: some View {
        steppingThroughMarkers(
            plot
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(speech.label)
                .accessibilityValue(spokenValue)
                .accessibilityChartDescriptor(audioGraph)
                .accessibilityFocused($voiceOverFocus)
        )
        .onChange(of: voiceOverFocus) { focused in
            // Off the chart, the header goes back to the value now.
            if !focused, pinned != nil {
                pinned = nil
                update(nil)
            }
        }
    }

    /// With markers, the element is adjustable: a swipe up or down steps
    /// through them. Without, there is nothing to step to.
    @ViewBuilder
    private func steppingThroughMarkers(_ content: some View) -> some View {
        if markers.isEmpty {
            content
        } else {
            content
                .accessibilityHint(speech.markerHint ?? "")
                .accessibilityAdjustableAction(step)
        }
    }

    /// The summary, or the pinned marker and where it falls: "Received
    /// 2.0000 XMR, Sep 20, 2026 at 3:05 PM, portfolio $1,234.56, 2 of 5".
    private var spokenValue: String {
        guard let pinned, let index = markers.firstIndex(of: pinned) else { return summary }
        return String(localized: "\(pinned.accessibilityLabel), \(pinned.accessibilityValue), \(index + 1) of \(markers.count)", comment: "VoiceOver: marker, its value, then position like 2 of 5")
    }

    /// Up is the next marker in time, down the one before. From none, up
    /// starts at the oldest and down at the newest.
    private func step(_ direction: AccessibilityAdjustmentDirection) {
        guard !markers.isEmpty else { return }
        let current = pinned.flatMap { markers.firstIndex(of: $0) }
        let next: Int
        switch direction {
        case .increment: next = current.map { min($0 + 1, markers.count - 1) } ?? 0
        case .decrement: next = current.map { max($0 - 1, 0) } ?? markers.count - 1
        @unknown default: return
        }
        pin(markers[next])
    }

    private var plot: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { drag in
                            if !touching {
                                touching = true
                                pinnedAtTouchStart = pinned
                                pinned = nil
                            }
                            if scrolling { return }
                            let dx = abs(drag.translation.width)
                            let dy = abs(drag.translation.height)
                            if selected == nil, dy > 16, dy > dx * 1.5 {
                                scrolling = true
                                return
                            }
                            select(at: drag.location)
                        }
                        .onEnded { drag in
                            let tapped = !scrolling
                                && abs(drag.translation.width) < 10 && abs(drag.translation.height) < 10
                            if tapped, let marker = marker(near: drag.location), marker != pinnedAtTouchStart {
                                pin(marker)
                            } else {
                                update(nil)
                            }
                            touching = false
                            scrolling = false
                            pinnedAtTouchStart = nil
                        }
                )

            if let point = selected,
               let x = proxy.position(forX: point[keyPath: timestamp]),
               let y = proxy.position(forY: point[keyPath: value]) {
                let px = plotFrame.minX + x
                let py = plotFrame.minY + y
                Path { path in
                    path.move(to: CGPoint(x: px, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: px, y: plotFrame.maxY))
                }
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))

                // On a marker, the marker itself shows the selection.
                if let marker = markers.first(where: { $0.timestamp == point[keyPath: timestamp] }) {
                    ChartMarkerBadge(style: marker.style, selected: true)
                        .position(x: px, y: py)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                        .position(x: px, y: py)
                }
            }
        }
        .onChange(of: points) { _ in
            // New range under the finger: the old sample no longer exists.
            pinned = nil
            update(nil)
        }
    }

    /// The marker closest to `location`, if one is within reach of a finger.
    private func marker(near location: CGPoint) -> ChartMarker? {
        markers
            .compactMap { marker -> (marker: ChartMarker, distance: CGFloat)? in
                guard let x = proxy.position(forX: marker.timestamp),
                      let y = proxy.position(forY: marker.value) else { return nil }
                let distance = hypot(plotFrame.minX + x - location.x, plotFrame.minY + y - location.y)
                return distance <= Self.markerHitRadius ? (marker, distance) : nil
            }
            .min { $0.distance < $1.distance }?
            .marker
    }

    private func pin(_ marker: ChartMarker) {
        guard let point = points.first(where: { $0[keyPath: timestamp] == marker.timestamp }) else {
            update(nil)
            return
        }
        pinned = marker
        update(point)
        HapticFeedback.shared.softTick()
    }

    private func select(at location: CGPoint) {
        let x = min(max(location.x - plotFrame.minX, 0), plotFrame.width)
        guard let date: Date = proxy.value(atX: x) else { return }
        update(points.nearestByTimestamp(to: date, timestampKeyPath: timestamp))
    }

    private func update(_ point: Point?) {
        guard point != selected else { return }
        selected = point
        onSelect(point)
    }
}

#Preview {
    PriceChartView()
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
