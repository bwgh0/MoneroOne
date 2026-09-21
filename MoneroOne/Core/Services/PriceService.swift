import Foundation
import Combine
import CommonCrypto
import WidgetKit

struct PriceDataPoint: Identifiable, Equatable {
    var id: Double { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let price: Double
}

@MainActor
class PriceService: ObservableObject {
    /// Outer bounds for a believable XMR price in any supported fiat currency.
    /// Deliberately wide — this rejects garbage (0, negative, NaN, $0.01,
    /// $10M), not unusual-but-real market moves.
    nonisolated private static let minPlausiblePrice: Double = 0.5
    nonisolated private static let maxPlausiblePrice: Double = 1_000_000
    /// Maximum accepted move between consecutive updates (refresh is every 5
    /// minutes).
    nonisolated private static let maxPriceDeviation: Double = 0.5
    /// Maximum age of a server-stamped response.
    nonisolated private static let maxResponseAge: TimeInterval = 3600

    nonisolated static func isPlausiblePrice(_ price: Double) -> Bool {
        price.isFinite && price >= minPlausiblePrice && price <= maxPlausiblePrice
    }

    @Published var xmrPrice: Double?
    @Published var priceChange24h: Double?
    @Published var lastUpdated: Date?
    @Published var selectedCurrency: String = "usd"
    @Published var isLoading = false
    @Published var error: String?
    /// Raw API samples per range, in USD, ascending in time. Never smoothed,
    /// resampled or patched: what the chart draws is what the API returned,
    /// so scrubbing, high/low and % change all report real prices.
    @Published private(set) var chartDataCache: [String: [PriceDataPoint]] = [:]
    private var chartDataTimestamps: [String: Date] = [:]
    private var chartFetchTasks: [String: Task<Void, Never>] = [:]
    @Published var currentChartRange: String = "7D"
    @Published private(set) var loadingChartRanges: Set<String> = []
    @Published var usdToSelectedRate: Double = 1.0

    /// True while a fetch is running for the range on screen.
    var isLoadingChart: Bool { loadingChartRanges.contains(currentChartRange) }

    /// Samples for the range on screen, ending at the live price.
    var chartData: [PriceDataPoint] { chartData(for: currentChartRange) }

    /// Samples for `range` plus the live price as a final point, so every
    /// range ends at "now" rather than at the last API interval. The tip is
    /// derived on read; the cache itself stays pure API data.
    func chartData(for range: String) -> [PriceDataPoint] {
        Self.chartSeries(samples: chartDataCache[range] ?? [], liveTip: liveTip)
    }

    /// The live price as a chart point, stamped with when it was fetched so
    /// its identity is stable between refreshes.
    private var liveTip: PriceDataPoint? {
        guard let price = xmrPrice, let at = lastUpdated, usdToSelectedRate > 0 else { return nil }
        return PriceDataPoint(timestamp: at, price: price / usdToSelectedRate)
    }

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes
    private var priceFetchTask: Task<Void, Never>?
    private var currencyChangeDebounceTask: Task<Void, Never>?

    // Retry configuration
    private let maxRetries = 3
    private let initialRetryDelay: TimeInterval = 2
    private let requestTimeout: TimeInterval = 15

    // URLSession with cert pinning for monero.one
    private lazy var priceSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: PriceCertPinningDelegate(), delegateQueue: nil)
    }()

    // Optional alert service for triggering price alerts
    weak var priceAlertService: PriceAlertService?

    static let supportedCurrencies = ["usd", "eur", "gbp", "cad", "aud", "jpy", "cny", "try", "rub", "chf", "brl", "inr", "krw", "mxn", "pln", "uah"]

    static let currencySymbols: [String: String] = [
        "usd": "$",
        "eur": "€",
        "gbp": "£",
        "cad": "C$",
        "aud": "A$",
        "jpy": "¥",
        "cny": "¥",
        "try": "₺",
        "rub": "₽",
        "chf": "Fr",
        "brl": "R$",
        "inr": "₹",
        "krw": "₩",
        "mxn": "MX$",
        "pln": "zł",
        "uah": "₴"
    ]

    init() {
        loadCurrency()
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
        // Idempotent: callable from multiple lifecycle hooks without double-firing.
        guard refreshTimer == nil else { return }

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
                guard let self else { return }
                await self.fetchPrice()
                // Keep the range on screen current. A stale chart with a live
                // tip draws one long straight segment out to "now".
                await self.fetchChartData(range: self.currentChartRange)
            }
        }
    }

    /// Refresh the price and the chart on screen when they have gone stale,
    /// for example after the app returns to the foreground.
    func refreshIfStale() async {
        let priceAge = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        if priceAge >= refreshInterval {
            await fetchPrice()
        }
        await fetchChartData(range: currentChartRange)
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
        }

        // Don't update loading state if this task was cancelled
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    /// Performs the actual price fetch via monero.one price API
    private func performPriceFetch() async throws {
        guard let url = URL(string: "https://monero.one/api/v1/price") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await priceSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(PriceResponse.self, from: data)

        guard !Task.isCancelled else { return }

        guard let quote = result.quotes[selectedCurrency] else {
            throw URLError(.cannotParseResponse)
        }

        // Sanity-check before this value is allowed anywhere near money math.
        // The fiat entry mode divides a fiat amount by this price to produce
        // the XMR that actually gets sent, so a bogus price silently inflates
        // (or deflates) the amount. Certificate pinning stops a network
        // attacker, but a compromised or malfunctioning backend is still on the
        // other side of it, and nothing else downstream validates this.
        guard Self.isPlausiblePrice(quote.price) else {
            throw PriceError.implausiblePrice(quote.price)
        }
        // Reject a big jump against the last known-good price rather than
        // acting on it. Legitimate XMR moves are nowhere near this in the
        // 5-minute refresh window; anything larger is more likely bad data.
        if let previous = xmrPrice, previous > 0 {
            let ratio = quote.price / previous
            guard ratio > (1 - Self.maxPriceDeviation), ratio < (1 + Self.maxPriceDeviation) else {
                throw PriceError.implausibleDeviation(previous: previous, new: quote.price)
            }
        }
        // A replayed or badly cached response would otherwise be
        // indistinguishable from a fresh one. `timestamp` was already decoded
        // and thrown away.
        let responseAge = Date().timeIntervalSince1970 - result.timestamp
        guard responseAge < Self.maxResponseAge else {
            throw PriceError.staleResponse(age: responseAge)
        }

        xmrPrice = quote.price
        priceChange24h = quote.change24h
        lastUpdated = Date()

        // Calculate USD to selected currency conversion rate for chart data
        if selectedCurrency == "usd" {
            usdToSelectedRate = 1.0
        } else if let usdQuote = result.quotes["usd"],
                  usdQuote.price > 0 {
            usdToSelectedRate = quote.price / usdQuote.price
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

        savePriceWidgetData()
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

    // MARK: - Chart Data

    /// Seconds of history each range shows. The API returns more than asked
    /// (about 1100 samples whatever the range), so the client trims.
    nonisolated static func chartSpan(for range: String) -> TimeInterval? {
        switch range {
        case "1D": return 24 * 60 * 60
        case "7D": return 7 * 24 * 60 * 60
        case "1M": return 30 * 24 * 60 * 60
        case "1Y": return 365 * 24 * 60 * 60
        default: return nil // "All"
        }
    }

    /// How long cached samples stay fresh: the API's sample interval for the
    /// range, so a refresh lands about when a new sample exists.
    nonisolated static func chartCacheTTL(for range: String) -> TimeInterval {
        switch range {
        case "1D": return 5 * 60
        case "7D": return 15 * 60
        default: return 60 * 60
        }
    }

    /// Selects the range a chart screen shows and makes sure it is loaded.
    func selectChartRange(_ range: String) {
        currentChartRange = range
        if chartDataCache[range] == nil {
            // Flag before the fetch task starts so the screen shows a
            // spinner on this frame rather than an empty chart.
            loadingChartRanges.insert(range)
        }
        Task { await fetchChartData(range: range) }
    }

    /// Fetch chart data for ranges: "1D", "7D", "1M", "1Y", "All".
    /// Returns at once when the cache is fresh, and joins an in-flight fetch
    /// for the same range rather than starting a second one.
    func fetchChartData(range: String = "7D", force: Bool = false) async {
        if !force, let cached = chartDataCache[range], !cached.isEmpty,
           let fetchedAt = chartDataTimestamps[range],
           Date().timeIntervalSince(fetchedAt) < Self.chartCacheTTL(for: range) {
            return
        }
        if let inflight = chartFetchTasks[range] {
            await inflight.value
            return
        }
        let task = Task {
            await performChartFetch(range: range)
            chartFetchTasks[range] = nil
        }
        chartFetchTasks[range] = task
        await task.value
    }

    private func performChartFetch(range: String) async {
        loadingChartRanges.insert(range)
        defer { loadingChartRanges.remove(range) }

        guard let url = URL(string: "https://monero.one/api/v1/chart?range=\(range)") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            let result = try JSONDecoder().decode(CMCChartResponse.self, from: data)
            let samples = Self.chartSamples(from: result.data.points, range: range, now: Date())
            guard samples.count >= 2 else { return }
            chartDataCache[range] = samples
            chartDataTimestamps[range] = Date()
            if range == "1D" {
                savePriceWidgetData()
            }
        } catch {
            // Keep existing data on error
        }
    }

    /// Turns raw API points into the samples a range draws. Pure so it can
    /// be tested. Drops unparsable, non-finite and non-positive prices,
    /// keeps one sample per timestamp, sorts, trims to the range's span and
    /// removes isolated spikes. No smoothing and no resampling: every point
    /// drawn is a real sample.
    nonisolated static func chartSamples(from points: [CMCPoint], range: String, now: Date) -> [PriceDataPoint] {
        var byTime: [Double: Double] = [:]
        for point in points {
            guard let ts = Double(point.s), ts.isFinite,
                  let price = point.v.first, price.isFinite, price > 0 else { continue }
            byTime[ts] = price
        }
        var samples = byTime
            .map { PriceDataPoint(timestamp: Date(timeIntervalSince1970: $0.key), price: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
        if let span = chartSpan(for: range) {
            let cutoff = now.addingTimeInterval(-span)
            samples.removeAll { $0.timestamp < cutoff }
        }
        return removingIsolatedSpikes(samples)
    }

    /// Drops an interior sample only when it is more than `factor` away from
    /// both the sample before and the sample after it. A real move persists
    /// into the next sample; a feed glitch does not. A level-based filter
    /// (against the median) is wrong here: it deleted 2014-2017 from "All".
    nonisolated static func removingIsolatedSpikes(_ samples: [PriceDataPoint], factor: Double = 5) -> [PriceDataPoint] {
        guard samples.count >= 3 else { return samples }
        var kept: [PriceDataPoint] = []
        kept.reserveCapacity(samples.count)
        for (i, sample) in samples.enumerated() {
            if i > 0, i < samples.count - 1 {
                let prev = samples[i - 1].price
                let next = samples[i + 1].price
                let farFromPrev = sample.price > prev * factor || sample.price < prev / factor
                let farFromNext = sample.price > next * factor || sample.price < next / factor
                if farFromPrev && farFromNext { continue }
            }
            kept.append(sample)
        }
        return kept
    }

    /// The drawn series: the samples, plus the live price as a final point
    /// when it is newer than the last sample. Samples are never altered.
    nonisolated static func chartSeries(samples: [PriceDataPoint], liveTip: PriceDataPoint?) -> [PriceDataPoint] {
        guard let tip = liveTip, let last = samples.last, tip.timestamp > last.timestamp else { return samples }
        return samples + [tip]
    }

    /// Y axis bounds for a set of values: the data's own min and max with a
    /// little headroom, so the chart never clips a real sample. Derived on
    /// every read; a cached domain went stale when the live tip or the
    /// currency changed.
    nonisolated static func chartYDomain(for values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return 0...100 }
        if high > low {
            let padding = (high - low) * 0.05
            return (low - padding)...(high + padding)
        }
        // Flat line: give it a band to sit in.
        let padding = max(abs(low) * 0.05, 1)
        return (low - padding)...(high + padding)
    }

    /// Sparkline for the price widget: half-hour slots ending now, each the
    /// nearest real sample, so the widget's "one slot = 30 minutes" axis
    /// labels hold. Leading slots with no sample nearby are dropped rather
    /// than padded with a repeated value.
    nonisolated static func widgetSparkline(from samples: [PriceDataPoint], rate: Double, now: Date, slots: Int = 48) -> [Double] {
        let slotLength: TimeInterval = 30 * 60
        let times = (0..<slots).map { now.addingTimeInterval(-Double(slots - 1 - $0) * slotLength) }
        guard let firstCovered = times.firstIndex(where: { at in
            samples.nearestByTimestamp(to: at, timestampKeyPath: \.timestamp)
                .map { abs($0.timestamp.timeIntervalSince(at)) < slotLength / 2 } ?? false
        }) else { return [] }
        return times[firstCovered...].compactMap { at in
            samples.nearestByTimestamp(to: at, timestampKeyPath: \.timestamp).map { $0.price * rate }
        }
    }

    var priceRange: (min: Double, max: Double)? {
        guard !chartData.isEmpty else { return nil }
        // Apply currency conversion (chart data is always in USD)
        let prices = chartData.map { $0.price * usdToSelectedRate }
        return (prices.min() ?? 0, prices.max() ?? 0)
    }

    // MARK: - Widget Data

    /// Save price data to widget data store
    func savePriceWidgetData() {
        // Serialized read-modify-write: only the price fields change here, the
        // wallet fields written by WalletManager are left untouched.
        WidgetDataManager.shared.update { widgetData in
        // Update with current price data
        widgetData.currentPrice = xmrPrice
        widgetData.priceChange24h = priceChange24h
        widgetData.priceCurrency = selectedCurrency
        widgetData.priceLastUpdated = lastUpdated

        // Always use 24h (1D) chart data for widget sparkline
        let dayData = chartData(for: "1D")
        if !dayData.isEmpty {
            let rate = usdToSelectedRate
            widgetData.priceChartPoints = Self.widgetSparkline(from: dayData, rate: rate, now: Date())
            // 24h high/low from every real sample, not the sparkline subset
            let prices = dayData.map { $0.price * rate }
            widgetData.priceHigh24h = prices.max()
            widgetData.priceLow24h = prices.min()
        }

        }

        // Reload widget timelines
        WidgetCenter.shared.reloadTimelines(ofKind: "PriceWidget")
    }
}

// MARK: - Price API Response

struct PriceResponse: Codable {
    let quotes: [String: PriceQuote]
    let timestamp: Double
}

/// Reasons a price response was rejected. Surfaced instead of being applied —
/// the previous value (and the "last updated" stamp the UI shows) stays put, so
/// a bad response can't quietly change what a send is worth.
enum PriceError: LocalizedError {
    case implausiblePrice(Double)
    case implausibleDeviation(previous: Double, new: Double)
    case staleResponse(age: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .implausiblePrice:
            return "Received an implausible XMR price. Keeping the last known value."
        case .implausibleDeviation:
            return "XMR price moved implausibly far in one update. Keeping the last known value."
        case .staleResponse:
            return "Received an out-of-date price response. Keeping the last known value."
        }
    }
}

struct PriceQuote: Codable {
    let price: Double
    let change24h: Double
}

// MARK: - Chart API Response

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

// MARK: - Certificate Pinning

/// Pins the monero.one TLS certificate to prevent MITM price manipulation.
/// Hashes are SHA-256 of the SubjectPublicKeyInfo (SPKI) DER encoding.
/// Regenerate with:
///   openssl s_client -connect monero.one:443 -servername monero.one 2>/dev/null \
///     | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
///     | openssl dgst -sha256 -binary | base64
private class PriceCertPinningDelegate: NSObject, URLSessionDelegate {
    // Leaf cert + intermediate CA for rotation tolerance
    static let pinnedSPKIHashes: Set<String> = [
        "RR2KH1dazA/4qlmld7f1kMO4bdCrvpsEYr6yqKMWsn0=",  // monero.one leaf
        "G9LNNAql897egYsabashkzUCTEJkWBzgoEtk8X/678c=",  // intermediate CA
    ]

    // ASN.1 header for RSA 2048 SubjectPublicKeyInfo
    // SecKeyCopyExternalRepresentation returns raw key bytes without this header,
    // but the openssl-derived hashes include it, so we must prepend it.
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "monero.one",
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the trust chain first
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check each certificate in the chain for a pinned SPKI hash
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        for cert in certChain {
            guard let publicKey = SecCertificateCopyKey(cert),
                  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                continue
            }

            // Rebuild the full SPKI by prepending the ASN.1 header to the raw key
            var spkiData = Data(Self.rsa2048SPKIHeader)
            spkiData.append(publicKeyData)

            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            spkiData.withUnsafeBytes { bytes in
                _ = CC_SHA256(bytes.baseAddress, CC_LONG(spkiData.count), &hash)
            }
            let hashBase64 = Data(hash).base64EncodedString()

            if Self.pinnedSPKIHashes.contains(hashBase64) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pinned hash matched — reject connection
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
