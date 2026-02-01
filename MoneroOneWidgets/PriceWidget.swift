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

        // Widget extensions have limited runtime (~10-30 seconds) and network is unreliable.
        // Instead of fetching data ourselves, we rely on cached data prepared by the main app.
        // The main app's PriceService saves data and triggers WidgetCenter.shared.reloadTimelines().

        let data: WidgetData
        if let cached = WidgetDataManager.shared.load(), cached.currentPrice != nil {
            os_log("✅ Using cached price data: %{public}@", log: widgetLog, type: .info, String(describing: cached.currentPrice))
            data = cached
        } else {
            os_log("⚠️ No cached data available - waiting for main app", log: widgetLog, type: .info)
            data = WidgetDataManager.pricePlaceholder
        }

        let entry = PriceEntry(date: Date(), data: data)

        // Determine refresh interval based on data availability
        let hasData = data.currentPrice != nil
        let refreshMinutes = hasData ? 15 : 2  // Retry sooner if no data (waiting for app)
        os_log("⏱️ Next refresh in %d minutes (hasData=%d)", log: widgetLog, type: .info, refreshMinutes, hasData ? 1 : 0)

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
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

            Text("Open MoneroOne to load")
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

        // Calculate nice Y-axis values within the actual data range
        let yAxisMin = minVal - padding
        let yAxisMax = maxVal + padding
        let yAxisValues = [yAxisMin, (yAxisMin + yAxisMax) / 2, yAxisMax]

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
            AxisMarks(position: .trailing, values: yAxisValues) { value in
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
        .chartYScale(domain: yAxisMin...yAxisMax)
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
