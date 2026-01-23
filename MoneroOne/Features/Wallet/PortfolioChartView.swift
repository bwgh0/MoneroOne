import SwiftUI
import Charts

struct PortfolioDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct PortfolioChartView: View {
    let balance: Decimal
    @ObservedObject var priceService: PriceService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?

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

    private var portfolioData: [PortfolioDataPoint] {
        priceService.chartData.map { point in
            PortfolioDataPoint(
                timestamp: point.timestamp,
                value: balanceDouble * point.price
            )
        }
    }

    private var selectedPoint: PortfolioDataPoint? {
        guard let selectedDate = selectedDate else { return nil }
        return portfolioData.min(by: {
            abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
        })
    }

    private var currentPortfolioValue: Double? {
        guard let price = priceService.xmrPrice else { return nil }
        return balanceDouble * price
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
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
        }
    }

    // MARK: - Portfolio Header

    private var displayValue: Double? {
        selectedPoint?.value ?? currentPortfolioValue
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

                if let selectedPoint = selectedPoint {
                    Text(formatSelectedDate(selectedPoint.timestamp))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(formatXMR(balance) + " XMR")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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

    private var chartYDomain: ClosedRange<Double> {
        guard let range = portfolioRange else { return 0...100 }
        let padding = (range.max - range.min) * 0.05
        return (range.min - padding)...(range.max + padding)
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && portfolioData.isEmpty {
                chartPlaceholder
            } else if portfolioData.isEmpty || balanceDouble == 0 {
                emptyChartState
            } else {
                Chart {
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

                    if let selectedPoint = selectedPoint {
                        RuleMark(x: .value("Selected", selectedPoint.timestamp))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))

                        PointMark(
                            x: .value("Time", selectedPoint.timestamp),
                            y: .value("Value", selectedPoint.value)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(100)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: xAxisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let price = value.as(Double.self) {
                                Text(formatCompactCurrency(price))
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

    private func formatCompactCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = priceService.selectedCurrency.uppercased()
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}

#Preview {
    PortfolioChartView(
        balance: 1.234567,
        priceService: PriceService()
    )
}
