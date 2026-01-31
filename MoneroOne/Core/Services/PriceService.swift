import Foundation
import Combine
import WidgetKit

struct PriceDataPoint: Identifiable, Equatable {
    var id: Double { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let price: Double
}

@MainActor
class PriceService: ObservableObject {
    @Published var xmrPrice: Double?
    @Published var priceChange24h: Double?
    @Published var lastUpdated: Date?
    @Published var selectedCurrency: String = "usd"
    @Published var isLoading = false
    @Published var error: String?
    @Published var chartDataCache: [String: [PriceDataPoint]] = [:]
    @Published var currentChartRange: String = "7D"
    @Published var isLoadingChart = false

    var chartData: [PriceDataPoint] {
        chartDataCache[currentChartRange] ?? []
    }
    @Published var usdToSelectedRate: Double = 1.0

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 60 // 1 minute

    // Optional alert service for triggering price alerts
    weak var priceAlertService: PriceAlertService?

    static let supportedCurrencies = ["usd", "eur", "gbp", "cad", "aud", "jpy", "cny"]

    static let currencySymbols: [String: String] = [
        "usd": "$",
        "eur": "€",
        "gbp": "£",
        "cad": "C$",
        "aud": "A$",
        "jpy": "¥",
        "cny": "¥"
    ]

    init() {
        loadCurrency()
        startAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func loadCurrency() {
        if let saved = UserDefaults.standard.string(forKey: "selectedCurrency") {
            selectedCurrency = saved
        }
    }

    func setCurrency(_ currency: String) {
        selectedCurrency = currency
        UserDefaults.standard.set(currency, forKey: "selectedCurrency")
        Task {
            await fetchPrice()
        }
    }

    var currencySymbol: String {
        Self.currencySymbols[selectedCurrency] ?? "$"
    }

    func startAutoRefresh() {
        Task {
            await fetchPrice()
            // Prefetch default chart data (7D) so it's ready when user opens chart
            await fetchChartData(range: "7D")
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchPrice()
            }
        }
    }

    func fetchPrice() async {
        isLoading = true
        error = nil

        // Fetch both selected currency and USD (for chart conversion)
        let currencies = selectedCurrency == "usd" ? "usd" : "\(selectedCurrency),usd"
        let urlString = "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=\(currencies)&include_24hr_change=true"

        guard let url = URL(string: urlString) else {
            error = "Invalid URL"
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                error = "Server error"
                isLoading = false
                return
            }

            let result = try JSONDecoder().decode(CoinGeckoResponse.self, from: data)

            if let moneroData = result.monero {
                xmrPrice = moneroData[selectedCurrency]
                priceChange24h = moneroData["\(selectedCurrency)_24h_change"]
                lastUpdated = Date()

                // Calculate USD to selected currency conversion rate for chart data
                if selectedCurrency == "usd" {
                    usdToSelectedRate = 1.0
                } else if let selectedPrice = moneroData[selectedCurrency],
                          let usdPrice = moneroData["usd"],
                          usdPrice > 0 {
                    // Rate = selectedCurrency / USD (e.g., GBP/USD)
                    usdToSelectedRate = selectedPrice / usdPrice
                }

                // Check price alerts
                if let price = xmrPrice, let alertService = priceAlertService {
                    let triggered = alertService.checkAlerts(
                        currentPrice: price,
                        currency: selectedCurrency
                    )
                    for alert in triggered {
                        PriceAlertNotificationManager.shared.sendAlert(alert, currentPrice: price)
                    }
                }

                // Save price data for widget
                savePriceWidgetData()
            }
        } catch {
            self.error = "Failed to fetch price"
            print("Price fetch error: \(error)")
        }

        isLoading = false
    }

    func formatFiatValue(_ xmrAmount: Decimal) -> String? {
        guard let price = xmrPrice else { return nil }

        let fiatValue = (xmrAmount as NSDecimalNumber).doubleValue * price
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = selectedCurrency.uppercased()

        return formatter.string(from: NSNumber(value: fiatValue))
    }

    func formatPriceChange() -> String? {
        guard let change = priceChange24h else { return nil }
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    /// Fetch chart data using CoinMarketCap ranges: "1D", "7D", "1M", "1Y", "All"
    func fetchChartData(range: String = "7D") async {
        currentChartRange = range

        // Return cached data if available
        if chartDataCache[range] != nil {
            isLoadingChart = false
            return
        }

        isLoadingChart = true

        // Map range to interval (matching CMC website)
        let interval: String = {
            switch range {
            case "1D": return "5m"
            case "7D": return "15m"
            case "1M": return "1h"
            case "1Y": return "1d"
            case "All": return "7d"
            default: return "15m"
            }
        }()

        // Expected time span for filtering (in seconds)
        let expectedSeconds: TimeInterval? = {
            switch range {
            case "1D": return 24 * 60 * 60
            case "7D": return 7 * 24 * 60 * 60
            case "1M": return 30 * 24 * 60 * 60
            case "1Y": return 365 * 24 * 60 * 60
            case "All": return nil
            default: return nil
            }
        }()

        // CoinMarketCap API - id=328 is Monero, convertId=2781 is USD
        let urlString = "https://api.coinmarketcap.com/data-api/v3.3/cryptocurrency/detail/chart?id=328&interval=\(interval)&convertId=2781&range=\(range)"

        guard let url = URL(string: urlString) else {
            isLoadingChart = false
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Required headers for CMC API
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("https://coinmarketcap.com", forHTTPHeaderField: "origin")
        request.setValue("web", forHTTPHeaderField: "platform")
        request.setValue("https://coinmarketcap.com/", forHTTPHeaderField: "referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                isLoadingChart = false
                return
            }

            let result = try JSONDecoder().decode(CMCChartResponse.self, from: data)

            // Convert CMC data to PriceDataPoint array
            var allPoints = result.data.points.compactMap { point -> PriceDataPoint? in
                guard let timestamp = Double(point.s),
                      let price = point.v.first else { return nil }
                return PriceDataPoint(
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    price: price
                )
            }

            // Filter to only include data within the expected time range
            if let expectedSeconds = expectedSeconds {
                let cutoffDate = Date().addingTimeInterval(-expectedSeconds)
                allPoints = allPoints.filter { $0.timestamp >= cutoffDate }
            }

            // Downsample to max 100 points for smooth performance
            let maxPoints = 100
            var newChartData: [PriceDataPoint]

            if allPoints.count > maxPoints {
                let step = Double(allPoints.count) / Double(maxPoints)
                var sampledPoints: [PriceDataPoint] = []
                for i in 0..<maxPoints {
                    let index = Int(Double(i) * step)
                    if index < allPoints.count {
                        sampledPoints.append(allPoints[index])
                    }
                }
                if let last = allPoints.last {
                    sampledPoints.append(last)
                }
                newChartData = sampledPoints
            } else {
                newChartData = allPoints
            }

            if !newChartData.isEmpty {
                chartDataCache[range] = newChartData
                // Save updated chart data for widget
                savePriceWidgetData()
            }
        } catch {
            // Keep existing data on error
        }

        isLoadingChart = false
    }

    var priceRange: (min: Double, max: Double)? {
        guard !chartData.isEmpty else { return nil }
        // Apply currency conversion (chart data is always in USD from CMC API)
        let prices = chartData.map { $0.price * usdToSelectedRate }
        return (prices.min() ?? 0, prices.max() ?? 0)
    }

    // MARK: - Widget Data

    /// Save price data to widget data store
    func savePriceWidgetData() {
        // Load existing widget data or create new
        var widgetData = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder

        // Update with current price data
        widgetData.currentPrice = xmrPrice
        widgetData.priceChange24h = priceChange24h
        widgetData.priceCurrency = selectedCurrency
        widgetData.priceLastUpdated = lastUpdated

        // Downsample chart data for widget sparkline
        if !chartData.isEmpty {
            // Convert chart data to widget format (just Y values, applying currency conversion)
            let prices = chartData.map { $0.price * usdToSelectedRate }

            // Downsample to 48 points for smoother chart appearance
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
            } else {
                widgetData.priceChartPoints = prices
            }

            // Calculate 24h high/low from chart data
            widgetData.priceHigh24h = prices.max()
            widgetData.priceLow24h = prices.min()
        }

        // Save to widget data store
        WidgetDataManager.shared.save(widgetData)

        // Reload widget timelines
        WidgetCenter.shared.reloadTimelines(ofKind: "PriceWidget")
    }
}

// MARK: - CoinGecko Response

struct CoinGeckoResponse: Codable {
    let monero: [String: Double]?
}

struct MarketChartResponse: Codable {
    let prices: [[Double]]
}

// MARK: - CoinMarketCap Response

struct CMCChartResponse: Codable {
    let data: CMCChartData
}

struct CMCChartData: Codable {
    let points: [CMCPoint]
}

struct CMCPoint: Codable {
    let s: String  // timestamp as string
    let v: [Double]  // [price, volume, marketCap]
}
