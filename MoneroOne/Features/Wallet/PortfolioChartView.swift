import SwiftUI
import Charts

struct PortfolioDataPoint: Identifiable, Equatable {
    var id: Double { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let value: Double
}

struct PortfolioChartView: View {
    let balance: Decimal
    @ObservedObject var priceService: PriceService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedPoint: PortfolioDataPoint?

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
    /// (the API serves USD). Derived on read so it cannot drift from the
    /// price series or the header.
    private var portfolioData: [PortfolioDataPoint] {
        let scale = balanceDouble * priceService.usdToSelectedRate
        return priceService.chartData.map { PortfolioDataPoint(timestamp: $0.timestamp, value: $0.price * scale) }
    }

    private var portfolioRange: (min: Double, max: Double)? {
        guard !portfolioData.isEmpty else { return nil }
        let values = portfolioData.map { $0.value }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Portfolio Value Header
                    portfolioHeader

                    // Time Range Selector
                    timeRangeSelector

                    // Chart
                    chartSection

                    // Stats
                    statsSection
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
    private var portfolioValueChange: Double? {
        guard portfolioData.count >= 2 else { return nil }
        guard let firstValue = portfolioData.first?.value,
              let lastValue = portfolioData.last?.value,
              firstValue > 0 else { return nil }
        return ((lastValue - firstValue) / firstValue) * 100
    }

    private func formatValueChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    private var portfolioHeader: some View {
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

                // One slot for both states so the chart never moves on scrub.
                ZStack {
                    // Show portfolio change for selected time range
                    HStack(spacing: 12) {
                        Text(XMRFormatter.format(balance) + " XMR")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let change = portfolioValueChange {
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
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.6)
                        }

                        Text(selectedTimeRange.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(selectedPoint == nil ? 1 : 0)
                    .accessibilityHidden(selectedPoint != nil)

                    if let selectedPoint = selectedPoint {
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

    private var chartYDomain: ClosedRange<Double> {
        PriceService.chartYDomain(for: portfolioData.map { $0.value })
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && portfolioData.isEmpty {
                chartPlaceholder
            } else if portfolioData.isEmpty || balanceDouble == 0 {
                emptyChartState
            } else {
                SampledLineChart(
                    points: portfolioData,
                    domain: chartYDomain,
                    timestamp: \.timestamp,
                    value: \.value,
                    axes: .init(time: timeAxis, currencyCode: priceService.selectedCurrency.uppercased()),
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

    private var statsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portfolio Range")
                    .font(.headline)
                Spacer()
            }

            if let range = portfolioRange, balanceDouble > 0 {
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

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = priceService.selectedCurrency.uppercased()
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
}
