import Foundation
import Combine
import WidgetKit

struct PriceDataPoint: Identifiable, Equatable {
    var id: Double { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let price: Double
}

/// Chart smoothing mode for price charts
enum ChartSmoothingMode: String, CaseIterable {
    case highDensity = "High Density"    // More LTTB points only
    case emaSmoothed = "EMA Smoothed"    // LTTB + EMA smoothing
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
    @Published var chartSmoothingMode: ChartSmoothingMode = .emaSmoothed

    var chartData: [PriceDataPoint] {
        chartDataCache[currentChartRange] ?? []
    }
    @Published var usdToSelectedRate: Double = 1.0

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 60 // 1 minute
    private var priceFetchTask: Task<Void, Never>?
    private var currencyChangeDebounceTask: Task<Void, Never>?

    // Retry configuration
    private let maxRetries = 3
    private let initialRetryDelay: TimeInterval = 2
    private let requestTimeout: TimeInterval = 15

    // URLSession with explicit timeouts
    private lazy var priceSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

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
        // Cancel any pending debounce and in-flight fetch
        currencyChangeDebounceTask?.cancel()
        priceFetchTask?.cancel()

        selectedCurrency = currency
        UserDefaults.standard.set(currency, forKey: "selectedCurrency")

        // Clear stale price to trigger loading state and prevent showing
        // old price value with new currency symbol
        xmrPrice = nil
        priceChange24h = nil

        // Debounce: wait 300ms before fetching to avoid rate limits during rapid switching
        currencyChangeDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }

            priceFetchTask = Task {
                await fetchPrice()
            }
        }
    }

    var currencySymbol: String {
        Self.currencySymbols[selectedCurrency] ?? "$"
    }

    /// Execute an async operation with exponential backoff retry
    private func fetchWithRetry<T>(
        retries: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = initialRetryDelay

        for attempt in 1...retries {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2 // exponential backoff
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    func startAutoRefresh() {
        Task {
            await fetchPrice()
            // Prefetch ALL chart ranges for instant switching
            let ranges = ["7D", "1D", "1M", "1Y", "All"]
            for range in ranges {
                await fetchChartData(range: range)
            }
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

        do {
            try await fetchWithRetry(retries: maxRetries) {
                try await self.performPriceFetch()
            }
        } catch {
            // Don't update error state if this task was cancelled -
            // a newer task is handling the fetch
            guard !Task.isCancelled else { return }
            self.error = "Price unavailable"
            print("Price fetch error after retries: \(error)")
        }

        // Don't update loading state if this task was cancelled
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    /// Performs the actual price fetch - called by fetchWithRetry
    private func performPriceFetch() async throws {
        // Fetch both selected currency and USD (for chart conversion)
        let currencies = selectedCurrency == "usd" ? "usd" : "\(selectedCurrency),usd"
        let urlString = "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=\(currencies)&include_24hr_change=true"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await priceSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(CoinGeckoResponse.self, from: data)

        // Check if task was cancelled before updating price
        // This prevents stale responses from overwriting newer currency selections
        guard !Task.isCancelled else { return }

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
        } else {
            throw URLError(.cannotParseResponse)
        }
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

    /// LTTB (Largest Triangle Three Buckets) downsampling algorithm
    /// Preserves visual shape while reducing point count
    private func downsampleLTTB(_ data: [PriceDataPoint], targetCount: Int) -> [PriceDataPoint] {
        guard data.count > targetCount else { return data }
        guard targetCount >= 2 else { return data }

        var result: [PriceDataPoint] = []
        result.reserveCapacity(targetCount)

        // Always keep first point
        result.append(data[0])

        let bucketSize = Double(data.count - 2) / Double(targetCount - 2)
        var lastSelectedIndex = 0

        for i in 0..<(targetCount - 2) {
            // Calculate bucket range
            let bucketStart = Int(Double(i) * bucketSize) + 1
            let bucketEnd = Int(Double(i + 1) * bucketSize) + 1

            // Calculate average point of next bucket (for triangle calculation)
            let nextBucketStart = bucketEnd
            let nextBucketEnd = min(Int(Double(i + 2) * bucketSize) + 1, data.count - 1)

            var avgX: Double = 0
            var avgY: Double = 0
            let nextBucketCount = nextBucketEnd - nextBucketStart + 1

            for j in nextBucketStart...nextBucketEnd {
                avgX += data[j].timestamp.timeIntervalSince1970
                avgY += data[j].price
            }
            avgX /= Double(nextBucketCount)
            avgY /= Double(nextBucketCount)

            // Find point in current bucket that creates largest triangle
            let pointA = data[lastSelectedIndex]
            var maxArea: Double = -1
            var selectedIndex = bucketStart

            for j in bucketStart..<min(bucketEnd, data.count - 1) {
                let pointB = data[j]
                // Triangle area using cross product
                let area = abs(
                    (pointA.timestamp.timeIntervalSince1970 - avgX) * (pointB.price - pointA.price) -
                    (pointA.timestamp.timeIntervalSince1970 - pointB.timestamp.timeIntervalSince1970) * (avgY - pointA.price)
                )
                if area > maxArea {
                    maxArea = area
                    selectedIndex = j
                }
            }

            result.append(data[selectedIndex])
            lastSelectedIndex = selectedIndex
        }

        // Always keep last point
        result.append(data[data.count - 1])

        return result
    }

    /// Exponential Moving Average smoothing for smoother chart curves
    /// - Parameters:
    ///   - data: Array of price data points to smooth
    ///   - alpha: Smoothing factor (0-1). Lower = smoother but more lag. Default 0.3
    /// - Returns: Smoothed price data points preserving timestamps
    private func applyEMA(_ data: [PriceDataPoint], alpha: Double = 0.3) -> [PriceDataPoint] {
        guard data.count > 1 else { return data }

        var result: [PriceDataPoint] = []
        result.reserveCapacity(data.count)
        result.append(data[0])

        // Smooth all points except the last one
        for i in 1..<(data.count - 1) {
            let smoothedPrice = alpha * data[i].price + (1 - alpha) * result[i - 1].price
            result.append(PriceDataPoint(timestamp: data[i].timestamp, price: smoothedPrice))
        }

        // Keep last point unchanged so chart endpoint matches current price
        result.append(data[data.count - 1])

        return result
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

            // Downsample using LTTB - increased point counts for smoother curves
            let targetPoints: Int
            switch range {
            case "1D": targetPoints = 96   // was 48
            case "7D": targetPoints = 84   // was 42
            case "1M": targetPoints = 120  // was 60
            case "1Y": targetPoints = 104  // was 52
            default: targetPoints = 120    // was 60 ("All")
            }

            var newChartData = downsampleLTTB(allPoints, targetCount: targetPoints)

            // Apply EMA smoothing if enabled for flowing curves
            if chartSmoothingMode == .emaSmoothed {
                newChartData = applyEMA(newChartData, alpha: 0.3)
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

    /// Switch chart smoothing mode and regenerate all cached chart data
    func setChartSmoothingMode(_ mode: ChartSmoothingMode) {
        chartSmoothingMode = mode
        chartDataCache.removeAll()  // Clear cache to regenerate with new mode
        Task {
            let ranges = ["7D", "1D", "1M", "1Y", "All"]
            for range in ranges {
                await fetchChartData(range: range)
            }
        }
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

        // Always use 24h (1D) chart data for widget sparkline
        if let dayData = chartDataCache["1D"], !dayData.isEmpty {
            // Convert 24h chart data to widget format (just Y values, applying currency conversion)
            let prices = dayData.map { $0.price * usdToSelectedRate }

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
