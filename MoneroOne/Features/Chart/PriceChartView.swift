import SwiftUI
import Charts

struct PriceChartView: View {
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceAlertService: PriceAlertService
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?
    @State private var selectedPoint: PriceDataPoint?
    @State private var cachedYDomain: ClosedRange<Double> = 0...100

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

        /// Expected time span in seconds for filtering
        var expectedSeconds: TimeInterval? {
            switch self {
            case .day: return 24 * 60 * 60
            case .week: return 7 * 24 * 60 * 60
            case .month: return 30 * 24 * 60 * 60
            case .year: return 365 * 24 * 60 * 60
            case .all: return nil // No filter for All
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
                await priceService.fetchChartData(range: selectedTimeRange.apiRange)
            }
            .onChange(of: selectedTimeRange) { newValue in
                selectedDate = nil
                selectedPoint = nil
                priceService.chartData = [] // Clear for loading state
                Task {
                    await priceService.fetchChartData(range: newValue.apiRange)
                }
            }
            .onChange(of: selectedDate) { newDate in
                guard let date = newDate else {
                    selectedPoint = nil
                    return
                }
                // O(log n) binary search instead of O(n) linear search
                selectedPoint = priceService.chartData.nearestByTimestamp(to: date, timestampKeyPath: \.timestamp)
            }
            .onChange(of: priceService.chartData.count) { _ in
                // Recalculate domain only when data changes
                let rate = priceService.usdToSelectedRate
                let prices = priceService.chartData.map { $0.price * rate }
                guard let minPrice = prices.min(), let maxPrice = prices.max() else {
                    cachedYDomain = 0...100
                    return
                }
                let range = maxPrice - minPrice
                let padding = range * 0.05
                cachedYDomain = (minPrice - padding)...(maxPrice + padding)
            }
            .refreshable {
                await priceService.fetchPrice()
                await priceService.fetchChartData(range: selectedTimeRange.apiRange)
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
                }
            }
        }
    }

    // MARK: - Price Header

    private var displayPrice: Double? {
        // Chart data is in USD, convert selectedPoint to selected currency
        if let selectedPoint = selectedPoint {
            return selectedPoint.price * priceService.usdToSelectedRate
        }
        return priceService.xmrPrice
    }

    /// Calculate percentage change based on chart data for selected time range
    private var chartPriceChange: Double? {
        guard priceService.chartData.count >= 2 else { return nil }
        let rate = priceService.usdToSelectedRate
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

                if let selectedPoint = selectedPoint {
                    // Show selected date when interacting
                    Text(formatSelectedDate(selectedPoint.timestamp))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
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
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        Text(selectedTimeRange.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                ProgressView()
                    .scaleEffect(1.2)
            }
        }
        .padding(.vertical, 8)
    }

    private func formatSelectedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch selectedTimeRange {
        case .day:
            formatter.dateFormat = "h:mm a"
        case .week:
            formatter.dateFormat = "EEEE, h:mm a"
        case .month:
            formatter.dateFormat = "MMM d, h:mm a"
        case .year, .all:
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        GlassSegmentedPicker(selection: $selectedTimeRange) { range in
            range.rawValue
        }
    }

    // MARK: - Chart Section

    private var chartPriceRange: (min: Double, max: Double) {
        // Apply currency conversion (chart data is always in USD from CMC API)
        let rate = priceService.usdToSelectedRate
        let prices = priceService.chartData.map { $0.price * rate }
        guard let minPrice = prices.min(), let maxPrice = prices.max() else {
            return (0, 100)
        }
        return (minPrice, maxPrice)
    }

    private var chartYDomain: ClosedRange<Double> {
        cachedYDomain
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && priceService.chartData.isEmpty {
                chartPlaceholder
            } else if priceService.chartData.isEmpty {
                emptyChartState
            } else {
                // Apple Swift Charts
                // Note: Chart data is in USD, apply currency conversion
                let rate = priceService.usdToSelectedRate
                Chart {
                    // Area fill - use yStart to prevent going below x-axis
                    ForEach(priceService.chartData) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Min", chartYDomain.lowerBound),
                            yEnd: .value("Price", point.price * rate)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.4), Color.orange.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Price", point.price * rate)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }

                    // Selection indicator - vertical line and dot
                    if let selectedPoint = selectedPoint {
                        RuleMark(x: .value("Selected", selectedPoint.timestamp))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                        PointMark(
                            x: .value("Time", selectedPoint.timestamp),
                            y: .value("Price", selectedPoint.price * rate)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(100)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: xAxisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let price = value.as(Double.self) {
                                Text(formatCompactPrice(price))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYScale(domain: chartYDomain)
                .chartXSelectionIfAvailable(value: $selectedDate)
                .frame(height: 240)
            }
        }
        .frame(height: 280)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedTimeRange {
        case .day:
            return .dateTime.hour()
        case .week:
            return .dateTime.weekday(.abbreviated)
        case .month:
            return .dateTime.month(.abbreviated).day()
        case .year:
            return .dateTime.month(.abbreviated).year(.twoDigits)
        case .all:
            return .dateTime.year()
        }
    }

    private func formatCompactPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = priceService.selectedCurrency.uppercased()
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: price)) ?? "\(Int(price))"
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
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - iOS 16 Compatibility

extension View {
    /// Applies chartXSelection on iOS 17+, no-op on iOS 16
    @ViewBuilder
    func chartXSelectionIfAvailable(value: Binding<Date?>) -> some View {
        if #available(iOS 17.0, *) {
            self.chartXSelection(value: value)
        } else {
            self
        }
    }
}

#Preview {
    PriceChartView()
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
