import SwiftUI
import Charts

/// Compact price chart card for iPad Command Center
/// Embeddable widget with integrated time range selector
struct CompactPriceChartCard: View {
    @EnvironmentObject var priceService: PriceService
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?
    @State private var selectedPoint: PriceDataPoint?
    @State private var cachedYDomain: ClosedRange<Double> = 0...100

    enum TimeRange: String, CaseIterable {
        case day = "24H"
        case week = "1W"
        case month = "1M"
        case year = "1Y"

        var apiRange: String {
            switch self {
            case .day: return "1D"
            case .week: return "7D"
            case .month: return "1M"
            case .year: return "1Y"
            }
        }
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

    var body: some View {
        VStack(spacing: 12) {
            // Header with price
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("XMR Price")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Chart data is in USD, convert selectedPoint to selected currency
                    let displayPrice: Double? = {
                        if let selectedPoint = selectedPoint {
                            return selectedPoint.price * priceService.usdToSelectedRate
                        }
                        return priceService.xmrPrice
                    }()
                    if let price = displayPrice {
                        Text(formatPrice(price))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.15), value: price)
                    } else {
                        Text("--")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Price change badge for selected time range
                if selectedPoint == nil {
                    HStack(spacing: 8) {
                        if let change = chartPriceChange {
                            HStack(spacing: 2) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2)
                                Text(formatChartPriceChange(change))
                                    .font(.caption)
                            }
                            .foregroundColor(change >= 0 ? .green : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                            .cornerRadius(8)
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.6)
                        }

                        Text(selectedTimeRange.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Time range selector (compact)
            CompactGlassSegmentedPicker(selection: $selectedTimeRange) { range in
                range.rawValue
            }

            // Chart
            chartView
                .frame(height: 140)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .task {
            await priceService.fetchChartData(range: selectedTimeRange.apiRange)
        }
        .onChange(of: selectedTimeRange) { newValue in
            selectedDate = nil
            selectedPoint = nil
            priceService.chartData = []
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
            updateCachedYDomain()
        }
    }

    // MARK: - Chart View

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

    private func updateCachedYDomain() {
        let (minPrice, maxPrice) = chartPriceRange
        let range = maxPrice - minPrice
        let padding = range * 0.05
        cachedYDomain = (minPrice - padding)...(maxPrice + padding)
    }

    @ViewBuilder
    private var chartView: some View {
        if priceService.isLoadingChart && priceService.chartData.isEmpty {
            VStack {
                ProgressView()
                Text("Loading...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if priceService.chartData.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Note: Chart data is in USD, apply currency conversion
            let rate = priceService.usdToSelectedRate
            Chart {
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

                if let selectedPoint = selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.timestamp))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                    PointMark(
                        x: .value("Time", selectedPoint.timestamp),
                        y: .value("Price", selectedPoint.price * rate)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(80)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: chartYDomain)
            .chartXSelectionIfAvailable(value: $selectedDate)
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

#Preview {
    CompactPriceChartCard()
        .environmentObject(PriceService())
        .padding()
}
