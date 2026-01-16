import SwiftUI
import Charts

struct PriceChartView: View {
    @EnvironmentObject var priceService: PriceService
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?

    private var selectedPoint: PriceDataPoint? {
        guard let selectedDate = selectedDate else { return nil }
        // Find the closest point to the selected date
        return priceService.chartData.min(by: {
            abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
        })
    }

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
            .onChange(of: selectedTimeRange) { _, newValue in
                selectedDate = nil
                priceService.chartData = [] // Clear for loading state
                Task {
                    await priceService.fetchChartData(range: newValue.apiRange)
                }
            }
            .refreshable {
                await priceService.fetchPrice()
                await priceService.fetchChartData(range: selectedTimeRange.apiRange)
            }
        }
    }

    // MARK: - Price Header

    private var displayPrice: Double? {
        selectedPoint?.price ?? priceService.xmrPrice
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
                    // Show 24h change when not interacting
                    HStack(spacing: 16) {
                        if let change = priceService.priceChange24h {
                            HStack(spacing: 4) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(priceService.formatPriceChange() ?? "")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(change >= 0 ? .green : .red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                            .cornerRadius(8)
                        }

                        Text("24h")
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
            }
        }
        .padding(4)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Chart Section

    private var chartPriceRange: (min: Double, max: Double) {
        let prices = priceService.chartData.map { $0.price }
        guard let minPrice = prices.min(), let maxPrice = prices.max() else {
            return (0, 100)
        }
        return (minPrice, maxPrice)
    }

    private var chartYDomain: ClosedRange<Double> {
        let (minPrice, maxPrice) = chartPriceRange
        // Add 5% padding on top and bottom for better visualization
        let range = maxPrice - minPrice
        let padding = range * 0.05
        return (minPrice - padding)...(maxPrice + padding)
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && priceService.chartData.isEmpty {
                chartPlaceholder
            } else if priceService.chartData.isEmpty {
                emptyChartState
            } else {
                // Apple Swift Charts
                Chart {
                    // Area fill - use yStart to prevent going below x-axis
                    ForEach(priceService.chartData) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Min", chartYDomain.lowerBound),
                            yEnd: .value("Price", point.price)
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
                            y: .value("Price", point.price)
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
                            y: .value("Price", selectedPoint.price)
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
                .chartXSelection(value: $selectedDate)
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

#Preview {
    PriceChartView()
        .environmentObject(PriceService())
}
