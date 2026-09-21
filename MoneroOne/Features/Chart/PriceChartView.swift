import SwiftUI
import Charts

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
                            .accessibilityLabel("Price change \(selectedTimeRange.rawValue), \(change >= 0 ? "up" : "down") \(formatChartPriceChange(change))")
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        Text(selectedTimeRange.rawValue)
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
            range.rawValue
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
                    onSelect: { selectedPoint = $0 }
                )
                .equatable()
                .frame(height: 240)
                .clipped()
                .accessibilityLabel("Price chart for \(selectedTimeRange.rawValue)")
                .accessibilityHint("Shows XMR price trend over the selected time range")
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
                        title: "\(selectedTimeRange.rawValue) High",
                        value: formatPrice(range.max),
                        color: .green
                    )

                    StatCard(
                        title: "\(selectedTimeRange.rawValue) Low",
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = priceService.selectedCurrency.uppercased()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: price)) ?? "\(price)"
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
        var ticks: [Date] = []
        var tick = firstTick(atOrAfter: span.lowerBound, calendar: calendar)
        while tick <= span.upperBound, ticks.count < 64 {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: step.component, value: step.count, to: tick) else { break }
            tick = next
        }
        return ticks
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

    private var step: (component: Calendar.Component, count: Int) {
        switch self {
        case .day: return (.hour, 5)  // unused: `dayTicks` restarts at midnight
        case .week: return (.day, 1)
        case .month: return (.day, 7)
        case .year: return (.month, 2)
        case .all: return (.year, 2)
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
    let onSelect: (Point?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.domain == rhs.domain && lhs.axes == rhs.axes
            && lhs.timestamp == rhs.timestamp && lhs.value == rhs.value
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

                LineMark(
                    x: .value("Time", point[keyPath: timestamp]),
                    y: .value("Value", point[keyPath: value])
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            }
        }
        .chartYScale(domain: domain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ScrubOverlay(
                    proxy: proxy,
                    plotFrame: Self.plotFrame(proxy, in: geometry),
                    points: points,
                    timestamp: timestamp,
                    value: value,
                    onSelect: onSelect
                )
            }
        }
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = span < 5 ? 2 : 0
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
    }
}

/// Touch or drag to read a sample; releasing clears it. The gesture runs
/// alongside the page's scroll view. The first clear move of a touch
/// decides its axis once: mostly vertical means the page is scrolling and
/// the touch is ignored until it ends; anything else scrubs.
private struct ScrubOverlay<Point: Identifiable & Equatable>: View {
    let proxy: ChartProxy
    let plotFrame: CGRect
    let points: [Point]
    let timestamp: KeyPath<Point, Date>
    let value: KeyPath<Point, Double>
    let onSelect: (Point?) -> Void

    @State private var selected: Point?
    @State private var scrolling = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { drag in
                            if scrolling { return }
                            let dx = abs(drag.translation.width)
                            let dy = abs(drag.translation.height)
                            if selected == nil, dy > 16, dy > dx * 1.5 {
                                scrolling = true
                                return
                            }
                            select(at: drag.location)
                        }
                        .onEnded { _ in
                            scrolling = false
                            update(nil)
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

                Circle()
                    .fill(Color.orange)
                    .frame(width: 10, height: 10)
                    .position(x: px, y: py)
            }
        }
        .onChange(of: points) { _ in
            // New range under the finger: the old sample no longer exists.
            update(nil)
        }
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
