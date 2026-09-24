import SwiftUI
import Charts

/// Combined chart card for iPad Command Center with Portfolio/Price toggle
struct ChartSwitcherCard: View {
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var walletManager: WalletManager
    let balance: Decimal

    @State private var chartMode: ChartMode = .portfolio
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedPricePoint: PriceDataPoint?
    @State private var selectedPortfolioPoint: PortfolioDataPoint?
    /// nil until the first load, which follows the first frame.
    @State private var ledger: BalanceLedger?
    @State private var seriesCache = PortfolioSeriesCache()

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

    private var currentPortfolioValue: Double? {
        guard let price = priceService.xmrPrice else { return nil }
        return balanceDouble * price
    }

    /// Price samples in the selected currency (the API serves USD), so the
    /// scrubbed value matches the header's currency.
    private var priceData: [PriceDataPoint] {
        let rate = priceService.usdToSelectedRate
        return priceService.chartData.map { PriceDataPoint(timestamp: $0.timestamp, price: $0.price * rate) }
    }

    /// Portfolio value at every real price sample, in the selected
    /// currency: the XMR held then times the price then, with a dot where
    /// transactions landed. Empty until the ledger loads.
    private var portfolioSeries: (points: [PortfolioDataPoint], markers: [ChartMarker]) {
        guard let ledger else { return ([], []) }
        return seriesCache.series(
            prices: priceService.chartData,
            rate: priceService.usdToSelectedRate,
            ledger: ledger,
            currency: priceService.selectedCurrency,
            formatValue: formatPrice
        )
    }

    private var portfolioData: [PortfolioDataPoint] { portfolioSeries.points }

    /// Changes whenever the balance or any transaction does, so the
    /// ledger reloads when a transaction arrives or confirms.
    private var ledgerKey: [String] {
        ["\(balance)"] + walletManager.transactions.map { "\($0.id) \($0.status)" }
    }

    /// Calculate percentage change based on chart data for selected time range
    private var chartPriceChange: Double? {
        guard priceService.chartData.count >= 2 else { return nil }
        guard let firstPrice = priceService.chartData.first?.price,
              let lastPrice = priceService.chartData.last?.price,
              firstPrice > 0 else { return nil }
        return ((lastPrice - firstPrice) / firstPrice) * 100
    }

    /// Calculate portfolio percentage change for selected time range
    private var portfolioValueChange: Double? {
        guard portfolioData.count >= 2 else { return nil }
        guard let firstValue = portfolioData.first?.value,
              let lastValue = portfolioData.last?.value,
              firstValue > 0 else { return nil }
        return ((lastValue - firstValue) / firstValue) * 100
    }

    private func formatChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    var body: some View {
        VStack(spacing: 12) {
            CompactGlassSegmentedPicker(selection: $chartMode) { mode in
                mode.rawValue
            }
            .accessibilityLabel("Chart mode")
            .accessibilityHint("Switch between portfolio and price chart")

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

                // Change badge for selected time range (works for both modes).
                // Hidden, not removed, while scrubbing so the row keeps its height.
                let scrubbing = selectedPricePoint != nil || selectedPortfolioPoint != nil
                Group {
                    let change = chartMode == .price ? chartPriceChange : portfolioValueChange
                    HStack(spacing: 8) {
                        if let change = change {
                            HStack(spacing: 2) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2)
                                Text(formatChange(change))
                                    .font(.caption)
                            }
                            .foregroundColor(change >= 0 ? .green : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.15))
                            .cornerRadius(8)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(chartMode == .price ? "Price" : "Portfolio") change, \(change >= 0 ? "up" : "down") \(formatChange(change))")
                        } else if priceService.isLoadingChart {
                            ProgressView()
                                .scaleEffect(0.6)
                        }

                        Text(selectedTimeRange.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .opacity(scrubbing ? 0 : 1)
                .accessibilityHidden(scrubbing)
            }

            // Time range selector
            CompactGlassSegmentedPicker(selection: $selectedTimeRange) { range in
                range.rawValue
            }

            chartView
                // Grows with the card so a tall column shows a tall chart
                // instead of a strip with empty space under it.
                .frame(minHeight: 100, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel("\(chartMode.rawValue) chart for \(selectedTimeRange.rawValue)")
                .accessibilityHint("Shows \(chartMode == .price ? "XMR price" : "portfolio value") trend")
        }
        .padding(16)
        .dashboardCard()
        .task {
            priceService.selectChartRange(selectedTimeRange.apiRange)
        }
        .task(id: ledgerKey) {
            // The newest transactions are in memory and draw at once;
            // the full list replaces them when it has loaded.
            if ledger == nil {
                ledger = walletManager.recentBalanceLedger
            }
            let full = await walletManager.balanceLedger()
            if !Task.isCancelled {
                ledger = full
            }
        }
        .onChange(of: selectedTimeRange) { newValue in
            selectedPricePoint = nil
            selectedPortfolioPoint = nil
            priceService.selectChartRange(newValue.apiRange)
        }
        .onChange(of: chartMode) { _ in
            selectedPricePoint = nil
            selectedPortfolioPoint = nil
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

    @ViewBuilder
    private var chartView: some View {
        if (priceService.isLoadingChart && priceService.chartData.isEmpty) || (chartMode == .portfolio && ledger == nil) {
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
            Group {
                if chartMode == .price {
                    SampledLineChart(
                        points: priceData,
                        domain: PriceService.chartYDomain(for: priceData.map { $0.price }),
                        timestamp: \.timestamp,
                        value: \.price,
                        axes: nil,
                        onSelect: { selectedPricePoint = $0 }
                    )
                    .equatable()
                } else {
                    let series = portfolioSeries
                    SampledLineChart(
                        points: series.points,
                        domain: PriceService.chartYDomain(for: series.points.map { $0.value }),
                        timestamp: \.timestamp,
                        value: \.value,
                        axes: nil,
                        markers: series.markers,
                        onSelect: { selectedPortfolioPoint = $0 }
                    )
                    .equatable()
                }
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

#Preview {
    ChartSwitcherCard(balance: 1.5)
        .environmentObject(PriceService())
        .environmentObject(WalletManager())
        .padding()
}
