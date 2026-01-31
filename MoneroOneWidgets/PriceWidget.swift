import SwiftUI
import WidgetKit
import Charts
import os.log

private let widgetLog = OSLog(subsystem: "one.monero.MoneroOne.WidgetsExtension", category: "Price")

struct PriceWidget: Widget {
    let kind = "PriceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PriceProvider()) { entry in
            if #available(iOS 17.0, *) {
                PriceWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                PriceWidgetView(entry: entry)
                    .padding()
                    .background(Color(.systemBackground))
            }
        }
        .configurationDisplayName("XMR Price")
        .description("View the current Monero price and 24h chart.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PriceEntry {
        PriceEntry(date: Date(), data: WidgetDataManager.pricePlaceholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceEntry) -> Void) {
        let cached = WidgetDataManager.shared.load()
        let data = (cached?.currentPrice != nil) ? cached! : WidgetDataManager.pricePlaceholder
        completion(PriceEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceEntry>) -> Void) {
        os_log("🔄 getTimeline called for PriceWidget", log: widgetLog, type: .info)

        Task {
            // Try to fetch fresh data from network
            let freshData = await fetchPriceData()

            let data: WidgetData
            if let freshData = freshData {
                os_log("✅ Fetched fresh price data: %{public}@", log: widgetLog, type: .info, String(describing: freshData.currentPrice))
                // Save fetched data for future use
                WidgetDataManager.shared.save(freshData)
                data = freshData
            } else {
                // Fall back to cached data, but only if it has price data
                os_log("⚠️ Using cached data", log: widgetLog, type: .info)
                if let cached = WidgetDataManager.shared.load(), cached.currentPrice != nil {
                    data = cached
                } else {
                    data = WidgetDataManager.pricePlaceholder
                }
            }

            os_log("📊 Price data: %{public}@", log: widgetLog, type: .info, String(describing: data.currentPrice))
            let entry = PriceEntry(date: Date(), data: data)

            // Determine refresh interval based on data completeness
            let hasCompleteData = data.currentPrice != nil && (data.priceChartPoints?.count ?? 0) > 1
            let refreshMinutes = hasCompleteData ? 15 : 2  // Retry sooner if data incomplete
            os_log("⏱️ Next refresh in %d minutes (complete=%d)", log: widgetLog, type: .info, refreshMinutes, hasCompleteData ? 1 : 0)

            let nextUpdate = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: Date())!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    /// Fetch price data directly from APIs
    private func fetchPriceData() async -> WidgetData? {
        // Load existing data to preserve user's currency preference
        var widgetData = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
        let currency = widgetData.priceCurrency ?? "usd"

        // Fetch current price from CoinGecko
        let currencies = currency == "usd" ? "usd" : "\(currency),usd"
        let priceUrlString = "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=\(currencies)&include_24hr_change=true"

        guard let priceUrl = URL(string: priceUrlString) else { return nil }

        do {
            let (priceData, priceResponse) = try await URLSession.shared.data(from: priceUrl)

            guard let httpResponse = priceResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            // Parse CoinGecko response
            if let json = try? JSONSerialization.jsonObject(with: priceData) as? [String: Any],
               let moneroData = json["monero"] as? [String: Double] {
                widgetData.currentPrice = moneroData[currency]
                widgetData.priceChange24h = moneroData["\(currency)_24h_change"]
                widgetData.priceLastUpdated = Date()

                // Calculate USD conversion rate for chart
                var usdToSelectedRate = 1.0
                if currency != "usd",
                   let selectedPrice = moneroData[currency],
                   let usdPrice = moneroData["usd"],
                   usdPrice > 0 {
                    usdToSelectedRate = selectedPrice / usdPrice
                }

                // Fetch chart data from CoinMarketCap
                let chartUrlString = "https://api.coinmarketcap.com/data-api/v3.3/cryptocurrency/detail/chart?id=328&interval=5m&convertId=2781&range=1D"

                if let chartUrl = URL(string: chartUrlString) {
                    var chartRequest = URLRequest(url: chartUrl)
                    chartRequest.setValue("application/json", forHTTPHeaderField: "accept")
                    chartRequest.setValue("https://coinmarketcap.com", forHTTPHeaderField: "origin")
                    chartRequest.setValue("web", forHTTPHeaderField: "platform")
                    chartRequest.setValue("https://coinmarketcap.com/", forHTTPHeaderField: "referer")

                    if let (chartData, chartResponse) = try? await URLSession.shared.data(for: chartRequest),
                       let chartHttpResponse = chartResponse as? HTTPURLResponse,
                       (200...299).contains(chartHttpResponse.statusCode),
                       let chartJson = try? JSONSerialization.jsonObject(with: chartData) as? [String: Any],
                       let dataDict = chartJson["data"] as? [String: Any],
                       let pointsArray = dataDict["points"] as? [[String: Any]] {

                        // Parse chart points - CMC returns an array of point objects
                        var chartPoints: [(timestamp: Double, price: Double)] = []
                        for point in pointsArray {
                            if let timestamp = point["s"] as? String,
                               let timestampDouble = Double(timestamp),
                               let values = point["v"] as? [Double],
                               let price = values.first {
                                chartPoints.append((timestamp: timestampDouble, price: price))
                            }
                        }

                        // Sort by timestamp and filter to last 24 hours
                        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
                        chartPoints = chartPoints
                            .filter { $0.timestamp >= cutoffDate }
                            .sorted { $0.timestamp < $1.timestamp }

                        // Convert to prices with currency conversion and downsample to 48 points
                        let prices = chartPoints.map { $0.price * usdToSelectedRate }
                        let targetPoints = 48

                        if prices.count > targetPoints {
                            let step = Double(prices.count) / Double(targetPoints)
                            var sampledPrices: [Double] = []
                            for i in 0..<targetPoints {
                                let index = Int(Double(i) * step)
                                if index < prices.count {
                                    sampledPrices.append(prices[index])
                                }
                            }
                            widgetData.priceChartPoints = sampledPrices
                        } else if !prices.isEmpty {
                            widgetData.priceChartPoints = prices
                        }

                        // Calculate high/low
                        if let chartPrices = widgetData.priceChartPoints, !chartPrices.isEmpty {
                            widgetData.priceHigh24h = chartPrices.max()
                            widgetData.priceLow24h = chartPrices.min()
                        }
                    }
                }
            }

            // Only return if we got a valid price
            if widgetData.currentPrice != nil {
                return widgetData
            }
            return nil
        } catch {
            os_log("❌ Failed to fetch price data: %{public}@", log: widgetLog, type: .error, error.localizedDescription)
            return nil
        }
    }
}

struct PriceEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct PriceWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PriceEntry

    var body: some View {
        if entry.data.currentPrice == nil {
            noDataView
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView
            default:
                smallView
            }
        }
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .scaleEffect(1.15)
                .clipShape(Circle())

            Text("XMR Price")
                .font(.headline.weight(.semibold))

            Text("Updating...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .widgetURL(URL(string: "moneroone://price"))
    }

    // MARK: - Small View (2x2) - "Price Glance"

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())

                Text("Monero")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()
            }

            Spacer()

            // Current price (large, monospace)
            if let price = entry.data.currentPrice {
                Text(formatPrice(price))
                    .font(.system(.title2, design: .monospaced).bold())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }

            // 24h change badge
            if let change = entry.data.priceChange24h {
                priceChangeBadge(change)
            }
        }
        .widgetURL(URL(string: "moneroone://price"))
    }

    // MARK: - Medium View (4x2) - "Price + Mini Chart"

    private var mediumView: some View {
        HStack(spacing: 12) {
            // Left side - Price info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image("MoneroSymbol")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .scaleEffect(1.15)
                        .clipShape(Circle())

                    Text("Monero")
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                if let price = entry.data.currentPrice {
                    Text(formatPrice(price))
                        .font(.system(.title2, design: .monospaced).bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }

                if let change = entry.data.priceChange24h {
                    priceChangeBadge(change)
                }

                // High/Low stats
                if let high = entry.data.priceHigh24h, let low = entry.data.priceLow24h {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green)
                            Text(formatCompactPrice(high))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.red)
                            Text(formatCompactPrice(low))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right side - Sparkline chart
            if let points = entry.data.priceChartPoints, points.count > 1 {
                sparklineChart(points: points)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, -16) // Extend to widget edge
                    .padding(.vertical, -16)
            }
        }
        .widgetURL(URL(string: "moneroone://price"))
    }

    // MARK: - Large View (4x4) - "Full Price Chart"

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Monero")
                        .font(.subheadline.weight(.semibold))
                    Text("XMR")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let price = entry.data.currentPrice {
                        Text(formatPrice(price))
                            .font(.system(.title3, design: .monospaced).bold())
                    }
                    if let change = entry.data.priceChange24h {
                        priceChangeBadge(change)
                    }
                }
            }

            // Chart with Y-axis labels
            if let points = entry.data.priceChartPoints, points.count > 1 {
                fullChart(points: points)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 8) // Space from header
                    .padding(.leading, -8) // Small extension for X-axis labels
                    .padding(.trailing, -4) // Small extension for Y-axis labels
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Text("Chart data unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer()
            }

            // Footer
            HStack {
                Text("24h")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)

                Spacer()

                if let lastUpdated = entry.data.priceLastUpdated {
                    Text("Updated \(lastUpdated, style: .relative) ago")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .widgetURL(URL(string: "moneroone://price"))
    }

    // MARK: - Helper Views

    private func priceChangeBadge(_ change: Double) -> some View {
        let isPositive = change >= 0
        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text(String(format: "%.2f%%", abs(change)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isPositive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
        .foregroundColor(isPositive ? .green : .red)
        .cornerRadius(6)
    }

    private func sparklineChart(points: [Double]) -> some View {
        let chartColor: Color = .orange

        return Chart(points.indices, id: \.self) { index in
            AreaMark(
                x: .value("", index),
                y: .value("", points[index])
            )
            .foregroundStyle(.linearGradient(
                colors: [chartColor.opacity(0.4), chartColor.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("", index),
                y: .value("", points[index])
            )
            .foregroundStyle(chartColor)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: (points.min() ?? 0) * 0.995 ... (points.max() ?? 1) * 1.005)
        .chartXScale(domain: 0...(points.count - 1))
        .chartPlotStyle { plotArea in
            plotArea.padding(.horizontal, 0)
        }
    }

    private func fullChart(points: [Double]) -> some View {
        let chartColor: Color = .orange
        let minVal = points.min() ?? 0
        let maxVal = points.max() ?? 1
        let range = maxVal - minVal
        let padding = range * 0.05

        return Chart(points.indices, id: \.self) { index in
            AreaMark(
                x: .value("", index),
                yStart: .value("", minVal - padding),
                yEnd: .value("", points[index])
            )
            .foregroundStyle(.linearGradient(
                colors: [chartColor.opacity(0.3), chartColor.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("", index),
                y: .value("", points[index])
            )
            .foregroundStyle(chartColor)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel {
                    if let index = value.as(Int.self) {
                        // 48 points = 24 hours, so each point = 30 min
                        let minutesAgo = (points.count - 1 - index) * 30
                        let pointTime = Date().addingTimeInterval(-Double(minutesAgo) * 60)
                        let hour = Calendar.current.component(.hour, from: pointTime)
                        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
                        let ampm = hour < 12 ? "a" : "p"
                        Text("\(displayHour)\(ampm)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(formatCompactPrice(price))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: (minVal - padding)...(maxVal + padding))
        .chartXScale(domain: 0...(points.count - 1))
        .chartPlotStyle { plotArea in
            plotArea.padding(.horizontal, 0)
        }
    }

    // MARK: - Formatting

    private var currencySymbol: String {
        let symbols: [String: String] = [
            "usd": "$", "eur": "€", "gbp": "£",
            "cad": "C$", "aud": "A$", "jpy": "¥", "cny": "¥"
        ]
        return symbols[entry.data.priceCurrency ?? "usd"] ?? "$"
    }

    private func formatPrice(_ price: Double) -> String {
        return "\(currencySymbol)\(String(format: "%.2f", price))"
    }

    private func formatCompactPrice(_ price: Double) -> String {
        return "\(currencySymbol)\(String(format: "%.0f", price))"
    }
}

struct PriceWidget_Previews: PreviewProvider {
    // Sample data for previews only
    static var previewData: WidgetData {
        WidgetData(
            balance: 0,
            balanceFormatted: "0.0000",
            syncStatus: .offline,
            lastUpdated: Date(),
            recentTransactions: [],
            isTestnet: false,
            isEnabled: true,
            currentPrice: 455.00,
            priceChange24h: -1.25,
            priceCurrency: "usd",
            priceChartPoints: [440, 445, 442, 448, 455, 460, 458, 462, 455, 450, 448, 452, 458, 465, 460, 455, 450, 445, 448, 452, 455, 458, 456, 455],
            priceHigh24h: 465.00,
            priceLow24h: 440.00,
            priceLastUpdated: Date()
        )
    }

    static var previews: some View {
        PriceWidgetView(entry: PriceEntry(date: Date(), data: previewData))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("Small")

        PriceWidgetView(entry: PriceEntry(date: Date(), data: previewData))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .previewDisplayName("Medium")

        PriceWidgetView(entry: PriceEntry(date: Date(), data: previewData))
            .previewContext(WidgetPreviewContext(family: .systemLarge))
            .previewDisplayName("Large")
    }
}
