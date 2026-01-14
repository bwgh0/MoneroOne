import SwiftUI

struct PriceChartView: View {
    @EnvironmentObject var priceService: PriceService
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedDate: Date?
    @State private var selectedPrice: Double?

    enum TimeRange: String, CaseIterable {
        case day = "24H"
        case week = "7D"
        case month = "30D"
        case threeMonths = "90D"

        var days: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .threeMonths: return 90
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
                await priceService.fetchChartData(days: selectedTimeRange.days)
            }
            .onChange(of: selectedTimeRange) { _, newValue in
                selectedDate = nil
                selectedPrice = nil
                Task {
                    await priceService.fetchChartData(days: newValue.days)
                }
            }
            .refreshable {
                await priceService.fetchPrice()
                await priceService.fetchChartData(days: selectedTimeRange.days)
            }
        }
    }

    // MARK: - Price Header

    private var displayPrice: Double? {
        selectedPrice ?? priceService.xmrPrice
    }

    private var priceHeader: some View {
        VStack(spacing: 8) {
            if let price = displayPrice {
                Text(formatPrice(price))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: price)

                if let selectedDate = selectedDate {
                    // Show selected date when interacting
                    Text(formatSelectedDate(selectedDate))
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
        case .month, .threeMonths:
            formatter.dateFormat = "MMM d, h:mm a"
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

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if priceService.isLoadingChart && priceService.chartData.isEmpty {
                chartPlaceholder
            } else if priceService.chartData.isEmpty {
                emptyChartState
            } else {
                // TradingView LightweightCharts
                LightweightChartView(
                    data: priceService.chartData,
                    selectedPrice: $selectedPrice,
                    selectedDate: $selectedDate
                )
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
