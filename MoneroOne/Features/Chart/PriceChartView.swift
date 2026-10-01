import SwiftUI
import Charts
import Accessibility

struct PriceChartView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var priceService: PriceService
    @Binding var selectedTimeRange: ChartTimeRange
    /// The sample under the finger, in the selected currency.
    @State private var selectedPoint: PriceDataPoint?

    var body: some View {
        VStack(spacing: 24) {
            priceHeader
            timeRangeSelector
            chartSection
            statsSection
        }
        .onChange(of: selectedTimeRange) { _, _ in
            selectedPoint = nil
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

    private var priceHeader: some View {
        ChartValueHeader {
            if let price = displayPrice {
                Text(formatPrice(price))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: price)
                    .accessibilityLabel("Current Monero price, \(formatPrice(price))")
            } else {
                ProgressView().scaleEffect(1.2)
            }
        } details: {
            ZStack {
                HStack(spacing: 12) {
                    ChartChangeBadge(change: chartPriceChange, timeAxis: timeAxis, isLoading: priceService.isLoadingChart)
                    Text(selectedTimeRange.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .opacity(selectedPoint == nil ? 1 : 0)
                .accessibilityHidden(selectedPoint != nil)

                if let selectedPoint {
                    Text(timeAxis.scrubLabel(for: selectedPoint.timestamp))
                        .foregroundColor(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selectedPoint == nil)
        }
    }

    private var timeAxis: ChartTimeAxis {
        ChartTimeAxis(rawValue: selectedTimeRange.apiRange) ?? .week
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        GlassSegmentedPicker(selection: $selectedTimeRange, accessibilityLabel: { range in
            (ChartTimeAxis(rawValue: range.apiRange) ?? .week).spokenName
        }) { range in
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
                // Not clipped: an axis label on a gridline at the plot's top
                // edge stands half above it, in the card's padding.
                .frame(height: 240)
            }
        }
        .frame(height: 280)
        .padding()
        .dashboardCard()
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
        ChartStatistics(
            title: "Statistics",
            range: priceService.priceRange,
            selectedTimeRange: selectedTimeRange,
            lastUpdated: priceService.lastUpdated,
            formatValue: formatPrice
        )
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
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

/// The instant a persistent chart selects, owned by the screen; nil is Now.
/// The chart reads it outside its own equality, so moving it redraws only
/// the cursor, never the marks or the axes of a long series.
@Observable
final class ChartCursor {
    var timestamp: Date?

    init(timestamp: Date? = nil) {
        self.timestamp = timestamp
    }
}

/// A sampled line with an independently updating inspection overlay. The
/// marks remain equatable when persistent selection changes, so scrubbing a
/// long series does not rebuild its chart content. Existing price charts use
/// transient inspection; wallet history opts into a parent-controlled cutoff.
/// VoiceOver sees one adjustable element and an Audio Graph of every sample.
struct SampledLineChart<Point: Identifiable & Equatable>: View, Equatable {
    @ScaledMetric(relativeTo: .caption2) private var axisLabelWidth: CGFloat = 64
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
    /// Badges drawn above the line and the area, each one whole.
    var markers: [ChartMarker] = []
    /// Keeps the line far enough inside the plot's edges that a marker on
    /// the first or last sample, or at the top or bottom, is whole. Set it
    /// in every range of a chart that can show markers, so the plot does
    /// not shift when a range has none.
    var insetsForMarkers = false
    let speech: ChartSpeech
    /// Persistent mode: a tap or drag selects until the parent sets the
    /// cursor back to nil (Now). nil keeps transient price inspection.
    var cursor: ChartCursor? = nil
    let onSelect: (Point?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.domain == rhs.domain && lhs.axes == rhs.axes
            && lhs.timestamp == rhs.timestamp && lhs.value == rhs.value
            && lhs.markers == rhs.markers && lhs.insetsForMarkers == rhs.insetsForMarkers
            && lhs.speech == rhs.speech && lhs.cursor === rhs.cursor
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
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(width: axisLabelWidth, alignment: .leading)
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

    /// A chart that fades after a cutoff or shows markers is one
    /// compositing group: the overlay fades the marks and parts markers
    /// from the line by erasing the chart's own pixels, never the card's.
    @ViewBuilder
    private var chart: some View {
        if cursor != nil || !markers.isEmpty {
            marksWithOverlay.compositingGroup()
        } else {
            marksWithOverlay
        }
    }

    private var marksWithOverlay: some View {
        SampledChartMarks(
            points: points, domain: domain, timestamp: timestamp, value: value,
            inset: insetsForMarkers ? ChartMarkerBadge.plotInset : 0
        )
        .equatable()
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
                    cursor: cursor,
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

/// The line and its area. Markers draw in the overlay, above these marks.
private struct SampledChartMarks<Point: Identifiable & Equatable>: View, Equatable {
    let points: [Point]
    let domain: ClosedRange<Double>
    let timestamp: KeyPath<Point, Date>
    let value: KeyPath<Point, Double>
    /// Space between the plot's edges and the line, in points.
    let inset: CGFloat

    private static var fill: LinearGradient {
        LinearGradient(colors: [Color.brand.opacity(0.4), Color.brand.opacity(0)], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        if inset > 0 {
            marks
                .chartXScale(range: .plotDimension(padding: inset))
                .chartYScale(domain: domain, range: .plotDimension(padding: inset))
        } else {
            marks
                .chartYScale(domain: domain)
        }
    }

    private var marks: some View {
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
                .foregroundStyle(Color.brand)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                .accessibilityHidden(true)
            }
        }
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

/// A disc in the activity row's color with its arrow. A ring around it
/// erases the chart under it, so the line parts around the disc in the
/// card's own color, glass or not. Selected, it grows and sits in a halo.
/// Draw it inside the chart's compositing group, or the ring cuts through
/// the card as well.
private struct ChartMarkerBadge: View {
    let style: ChartMarker.Style
    var selected = false
    /// After a past cutoff, the disc and its arrow fade as one shape.
    var faded = false

    /// What the line, the area and a marker keep after a past cutoff.
    static let fadedOpacity = 0.35
    private static let disc: CGFloat = 18
    private static let ring: CGFloat = 2
    private static let selectedScale: CGFloat = 1.25
    /// How far inside the plot's edges a marker's center stays, so a
    /// selected badge on the first or last sample, or at the top, is whole.
    static let plotInset = ((disc + 2 * ring) * selectedScale / 2).rounded(.up)

    private var tint: Color { style == .received ? .green : .brand }

    var body: some View {
        let scale = selected ? Self.selectedScale : 1
        ZStack {
            if selected {
                Circle().fill(tint.opacity(0.15)).frame(width: 38, height: 38)
            }
            Circle()
                .frame(width: (Self.disc + 2 * Self.ring) * scale, height: (Self.disc + 2 * Self.ring) * scale)
                .blendMode(.destinationOut)
            Image(systemName: style == .received ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.disc, height: Self.disc)
                .background(Circle().fill(tint))
                .scaleEffect(scale)
                .compositingGroup()
                .opacity(faded ? Self.fadedOpacity : 1)
        }
    }
}

/// Every marker, above the line and the area and each one whole. It is
/// equatable, so a scrub that crosses no marker leaves it alone.
private struct ChartMarkerLayer: View, Equatable {
    struct Badge: Identifiable, Equatable {
        let id: Date
        let style: ChartMarker.Style
        let center: CGPoint
        let faded: Bool
    }

    let badges: [Badge]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(badges) { badge in
                ChartMarkerBadge(style: badge.style, faded: badge.faded)
                    .position(badge.center)
            }
        }
    }
}

/// How a touch starts a chart's readout. A still finger starts it after
/// `holdDelay`, a sideways drag starts it at once, and a drag that starts
/// up or down belongs to the page's scroll view.
enum ChartTouch {
    /// How long a still finger rests before the readout starts.
    static let holdDelay: TimeInterval = 0.25
    /// How far a resting finger may drift.
    static let holdSlop: CGFloat = 8

    /// Whether a drag that has moved `translation` reads out the chart
    /// rather than scrolling the page.
    static func scrubs(_ translation: CGSize) -> Bool {
        abs(translation.height) <= abs(translation.width) * 1.5
    }
}

/// UIKit reads the chart's touches so that the page's scroll view can
/// still take a drag that starts on the chart: its pan waits only until
/// the touch is clearly neither a hold nor a sideways drag. A SwiftUI
/// drag gesture here kept the page from scrolling for the whole touch.
private struct ChartTouchSurface: UIViewRepresentable {
    enum Event {
        case began(CGPoint)
        case moved(CGPoint)
        /// Where the finger lifted, and how far it is from where it landed.
        case ended(CGPoint, CGSize)
        case cancelled
        case tapped(CGPoint)
    }

    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.track(_:)))
        hold.minimumPressDuration = ChartTouch.holdDelay
        hold.allowableMovement = ChartTouch.holdSlop
        let slide = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.track(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        for recognizer in [hold, slide, tap] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (Event) -> Void = { _ in }
        private var start: CGPoint = .zero

        @objc func track(_ recognizer: UIGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                let moved = (recognizer as? UIPanGestureRecognizer)?.translation(in: recognizer.view) ?? .zero
                start = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
                onEvent(.began(location))
            case .changed:
                onEvent(.moved(location))
            case .ended:
                onEvent(.ended(location, CGSize(width: location.x - start.x, height: location.y - start.y)))
            case .cancelled, .failed:
                onEvent(.cancelled)
            default:
                break
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            onEvent(.tapped(recognizer.location(in: recognizer.view)))
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            var moved = pan.translation(in: pan.view)
            if moved == .zero { moved = pan.velocity(in: pan.view) }
            return ChartTouch.scrubs(CGSize(width: moved.x, height: moved.y))
        }

        /// The page's scroll view waits for the hold and the sideways drag
        /// to fail; once either begins, the touch is the chart's.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            !(recognizer is UITapGestureRecognizer) && other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// Touch and hold, or a sideways drag, reads out a real sample; a drag
/// that starts up or down scrolls the page. Transient mode (price) drops
/// the readout on release unless a tap pinned a marker. Persistent mode
/// (wallet history) keeps the selection until the parent returns to Now.
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
    let cursor: ChartCursor?
    let onSelect: (Point?) -> Void

    private var persistsSelection: Bool { cursor != nil }

    @State private var selected: Point?
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
        .onAppear { synchronizeSelection() }
        .onChange(of: cursor?.timestamp) { _, _ in
            // Mid-drag the finger leads and the cursor follows a frame behind.
            if !touching { synchronizeSelection() }
        }
        .onChange(of: voiceOverFocus) { focused in
            // Off the chart, the header goes back to the value now.
            if !persistsSelection, !focused, pinned != nil {
                pinned = nil
                update(nil)
            }
        }
    }

    /// With markers, the element is adjustable: a swipe up or down steps
    /// through them. Without, there is nothing to step to.
    @ViewBuilder
    private func steppingThroughMarkers(_ content: some View) -> some View {
        if markers.isEmpty && !persistsSelection {
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
        if persistsSelection, let selected,
           let index = points.firstIndex(where: { $0[keyPath: timestamp] == selected[keyPath: timestamp] }) {
            let when = selected[keyPath: timestamp].formatted(date: .abbreviated, time: .shortened)
            let amount = speech.format(selected[keyPath: value])
            return String(localized: "\(when), \(amount), \(index + 1) of \(points.count)", comment: "VoiceOver: selected historical date, wallet value, and sample position")
        }
        guard let pinned, let index = markers.firstIndex(of: pinned) else { return summary }
        return String(localized: "\(pinned.accessibilityLabel), \(pinned.accessibilityValue), \(index + 1) of \(markers.count)", comment: "VoiceOver: marker, its value, then position like 2 of 5")
    }

    /// Up is the next marker in time, down the one before. From none, up
    /// starts at the oldest and down at the newest.
    private func step(_ direction: AccessibilityAdjustmentDirection) {
        if persistsSelection {
            guard !points.isEmpty else { return }
            let current = selected.flatMap { selection in points.firstIndex { $0[keyPath: timestamp] == selection[keyPath: timestamp] } } ?? points.count - 1
            let next: Int
            switch direction {
            case .increment: next = min(current + 1, points.count - 1)
            case .decrement: next = max(current - 1, 0)
            @unknown default: return
            }
            update(points[next])
            pinned = selected.flatMap { selection in markers.first { $0.timestamp == selection[keyPath: timestamp] } }
            return
        }
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

    /// Bottom to top: the fade after a past cutoff, the cutoff's rule, the
    /// markers, the selection, and the touch surface, which draws nothing.
    private var plot: some View {
        let spot = selectedSpot
        let cutoff = persistsSelection ? spot?.point[keyPath: timestamp] : nil
        return ZStack(alignment: .topLeading) {
            if let spot {
                if persistsSelection {
                    // Fades the line and the area after the cutoff. It
                    // erases part of what is under it in the chart's
                    // compositing group, so the card shows through and no
                    // color lies over the plot.
                    let width = max(plotFrame.maxX - spot.center.x, 0)
                    Rectangle()
                        .fill(.black.opacity(1 - ChartMarkerBadge.fadedOpacity))
                        .frame(width: width, height: plotFrame.height)
                        .position(x: spot.center.x + width / 2, y: plotFrame.midY)
                        .blendMode(.destinationOut)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Path { path in
                    path.move(to: CGPoint(x: spot.center.x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: spot.center.x, y: plotFrame.maxY))
                }
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                .allowsHitTesting(false)
            }

            ChartMarkerLayer(badges: badges(fadingAfter: cutoff))
                .equatable()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if let spot {
                // On a marker, the marker itself shows the selection.
                if let marker = markers.first(where: { $0.timestamp == spot.point[keyPath: timestamp] }) {
                    ChartMarkerBadge(style: marker.style, selected: true)
                        .position(spot.center)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 10, height: 10)
                        .position(spot.center)
                        .allowsHitTesting(false)
                }
            }

            ChartTouchSurface(onEvent: handle)
        }
        .onChange(of: points) { _ in
            if persistsSelection {
                synchronizeSelection()
            } else {
                // Transient price inspection clears when its series changes.
                pinned = nil
                update(nil)
            }
        }
    }

    /// The selected sample and where it sits in the overlay.
    private var selectedSpot: (point: Point, center: CGPoint)? {
        guard let point = selected,
              let x = proxy.position(forX: point[keyPath: timestamp]),
              let y = proxy.position(forY: point[keyPath: value]) else { return nil }
        return (point, CGPoint(x: plotFrame.minX + x, y: plotFrame.minY + y))
    }

    /// Each marker where it sits in the overlay. After a past cutoff, a
    /// marker fades as the line does.
    private func badges(fadingAfter cutoff: Date?) -> [ChartMarkerLayer.Badge] {
        markers.compactMap { marker in
            guard let x = proxy.position(forX: marker.timestamp),
                  let y = proxy.position(forY: marker.value) else { return nil }
            return ChartMarkerLayer.Badge(
                id: marker.timestamp,
                style: marker.style,
                center: CGPoint(x: plotFrame.minX + x, y: plotFrame.minY + y),
                faded: cutoff.map { marker.timestamp > $0 } ?? false
            )
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
        update(point)
        pinned = selected == nil ? nil : marker
        HapticFeedback.shared.softTick()
    }

    private func handle(_ event: ChartTouchSurface.Event) {
        switch event {
        case .began(let location):
            // A held or sliding finger replaces a pinned marker.
            touching = true
            pinnedAtTouchStart = pinned
            pinned = nil
            select(at: location)
        case .moved(let location):
            select(at: location)
        case .ended(let location, let travel):
            finish(at: location, tapped: abs(travel.width) < 10 && abs(travel.height) < 10)
        case .cancelled:
            if !persistsSelection { update(nil) }
            touching = false
            pinnedAtTouchStart = nil
        case .tapped(let location):
            pinnedAtTouchStart = pinned
            finish(at: location, tapped: true)
        }
    }

    /// A lifted finger. Persistent mode keeps what it chose; transient mode
    /// drops the readout unless a tap landed on a marker, and tapping the
    /// pinned marker again clears it.
    private func finish(at location: CGPoint, tapped: Bool) {
        if persistsSelection {
            if tapped, let marker = marker(near: location) {
                pin(marker)
            } else {
                select(at: location)
            }
        } else if tapped, let marker = marker(near: location), marker != pinnedAtTouchStart {
            pin(marker)
        } else {
            update(nil)
        }
        touching = false
        pinnedAtTouchStart = nil
    }

    private func select(at location: CGPoint) {
        let x = min(max(location.x - plotFrame.minX, 0), plotFrame.width)
        guard let date: Date = proxy.value(atX: x) else { return }
        update(points.nearestByTimestamp(to: date, timestampKeyPath: timestamp))
    }

    private func synchronizeSelection() {
        guard let cursor else { return }
        selected = cursor.timestamp.flatMap { date in points.first { $0[keyPath: timestamp] == date } }
        pinned = cursor.timestamp.flatMap { date in markers.first { $0.timestamp == date } }
    }

    private func update(_ point: Point?) {
        // The final sample is the live wallet, whose balance can include
        // transfers newer than the last price fetch. It has no past cutoff.
        let next = persistsSelection && point?[keyPath: timestamp] == points.last?[keyPath: timestamp] ? nil : point
        guard next != selected else { return }
        selected = next
        if next == nil { pinned = nil }
        onSelect(next)
    }
}

#Preview {
    @Previewable @State var path: [ChartView.Destination] = []
    ChartView(path: $path)
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
