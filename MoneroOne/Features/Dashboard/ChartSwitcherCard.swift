import SwiftUI
import Charts

/// Combined chart card for iPad Command Center with Portfolio/Price toggle
struct ChartSwitcherCard: View {
    @EnvironmentObject var priceService: PriceService
    let balance: Decimal

    @State private var chartMode: ChartMode = .portfolio
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?

    enum ChartMode: String, CaseIterable {
        case portfolio = "Portfolio"
        case price = "XMR Price"
    }

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

    private var balanceDouble: Double {
        (balance as NSDecimalNumber).doubleValue
    }

    // MARK: - Price Data

    private var selectedPricePoint: PriceDataPoint? {
        guard let selectedDate = selectedDate else { return nil }
        return priceService.chartData.min(by: {
            abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
        })
    }

    // MARK: - Portfolio Data

    private var portfolioData: [PortfolioPoint] {
        priceService.chartData.map { point in
            PortfolioPoint(id: point.id, timestamp: point.timestamp, value: balanceDouble * point.price)
        }
    }

    private var selectedPortfolioPoint: PortfolioPoint? {
        guard let selectedDate = selectedDate else { return nil }
        return portfolioData.min(by: {
            abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
        })
    }

    private var currentPortfolioValue: Double? {
        guard let price = priceService.xmrPrice else { return nil }
        return balanceDouble * price
    }

    var body: some View {
        VStack(spacing: 12) {
            // Mode switcher
            CompactGlassSegmentedPicker(selection: $chartMode) { mode in
                mode.rawValue
            }

            // Header with value
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if chartMode == .price {
                        priceHeader
                    } else {
                        portfolioHeader
                    }
                }

                Spacer()

                // 24h change badge (only for price mode when not selecting)
                if chartMode == .price, selectedDate == nil, let change = priceService.priceChange24h {
                    HStack(spacing: 2) {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text(priceService.formatPriceChange() ?? "")
                            .font(.caption)
                    }
                    .foregroundColor(change >= 0 ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                    .cornerRadius(8)
                }
            }

            // Time range selector
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
            priceService.chartData = []
            Task {
                await priceService.fetchChartData(range: newValue.apiRange)
            }
        }
        .onChange(of: chartMode) { _ in
            selectedDate = nil
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private var priceHeader: some View {
        Text("XMR Price")
            .font(.caption)
            .foregroundColor(.secondary)

        if let price = selectedPricePoint?.price ?? priceService.xmrPrice {
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

    @ViewBuilder
    private var portfolioHeader: some View {
        Text("Portfolio Value")
            .font(.caption)
            .foregroundColor(.secondary)

        if balanceDouble == 0 {
            Text("--")
                .font(.title2.weight(.bold))
                .foregroundColor(.secondary)
        } else if let value = selectedPortfolioPoint?.value ?? currentPortfolioValue {
            Text(formatPrice(value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: value)
        } else {
            Text("--")
                .font(.title2.weight(.bold))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Chart View

    private var chartPriceRange: (min: Double, max: Double) {
        let prices = priceService.chartData.map { $0.price }
        guard let minPrice = prices.min(), let maxPrice = prices.max() else {
            return (0, 100)
        }
        return (minPrice, maxPrice)
    }

    private var chartPortfolioRange: (min: Double, max: Double) {
        let values = portfolioData.map { $0.value }
        guard let minVal = values.min(), let maxVal = values.max() else {
            return (0, 100)
        }
        return (minVal, maxVal)
    }

    private var chartYDomain: ClosedRange<Double> {
        let range = chartMode == .price ? chartPriceRange : chartPortfolioRange
        let padding = (range.max - range.min) * 0.05
        return (range.min - padding)...(range.max + padding)
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
        } else if priceService.chartData.isEmpty || (chartMode == .portfolio && balanceDouble == 0) {
            VStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(chartMode == .portfolio && balanceDouble == 0 ? "Add XMR to see portfolio" : "No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                if chartMode == .price {
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

                    if let selectedPoint = selectedPricePoint {
                        RuleMark(x: .value("Selected", selectedPoint.timestamp))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                        PointMark(
                            x: .value("Time", selectedPoint.timestamp),
                            y: .value("Price", selectedPoint.price)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(80)
                    }
                } else {
                    ForEach(portfolioData) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Min", chartYDomain.lowerBound),
                            yEnd: .value("Value", point.value)
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
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }

                    if let selectedPoint = selectedPortfolioPoint {
                        RuleMark(x: .value("Selected", selectedPoint.timestamp))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                        PointMark(
                            x: .value("Time", selectedPoint.timestamp),
                            y: .value("Value", selectedPoint.value)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(80)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: chartYDomain)
            .chartXSelectionIfAvailable(value: $selectedDate)
            .animation(.smooth(duration: 0.15), value: selectedPricePoint?.id)
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

// MARK: - Portfolio Point

private struct PortfolioPoint: Identifiable {
    let id: UUID
    let timestamp: Date
    let value: Double
}

#Preview {
    ChartSwitcherCard(balance: 1.5)
        .environmentObject(PriceService())
        .padding()
}
