import Foundation
import Combine

/// One XMR price sample in a fiat currency.
struct PriceHistoryPoint: Codable, Equatable {
    let timestamp: Date
    let price: Double
}

/// What lands on disk for one currency: the samples and when they were
/// fetched, so a fresh cache skips the network on the next launch.
struct PriceHistoryCache: Codable, Equatable {
    let currency: String
    let fetchedAt: Date
    let points: [PriceHistoryPoint]
}

/// Wire shape of `GET /api/v1/history?currency=<code>`. `points` is an
/// ascending list of `[unixSeconds, price]` pairs: daily for the last few
/// years, weekly before that, back to 2014. `timestamp` is milliseconds.
struct PriceHistoryResponse: Decodable {
    let currency: String
    let points: [[Double]]
    let timestamp: Double
}

/// XMR price history in the selected fiat currency, for "what was this
/// worth when it happened". Kept in memory and on disk per currency, and
/// reloaded when the currency changes. Display only: nothing here feeds
/// money math, which is why the chart's plain session is enough.
@MainActor
final class PriceHistoryService: ObservableObject {
    /// Samples ascending in time, priced in `currency`.
    @Published private(set) var points: [PriceHistoryPoint] = []
    /// Lowercase code the loaded `points` are priced in.
    @Published private(set) var currency: String
    private(set) var fetchedAt: Date?

    /// How long a fetch stays fresh. The server caches for an hour too.
    nonisolated static let cacheTTL: TimeInterval = 60 * 60
    /// Dates this close to now use the live price: a daily sample is a
    /// worse answer than the price already on screen.
    nonisolated static let liveWindow: TimeInterval = 24 * 60 * 60

    private let priceService: PriceService
    private let cacheDirectory: URL?
    private let session: URLSession
    private var started = false
    private var refreshTimer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        priceService: PriceService,
        cacheDirectory: URL? = PriceHistoryService.defaultCacheDirectory,
        session: URLSession = .shared
    ) {
        self.priceService = priceService
        self.cacheDirectory = cacheDirectory
        self.session = session
        currency = priceService.selectedCurrency
        loadCache(for: currency)

        // `dropFirst` skips the replay of the current value; the cache for
        // it is already loaded above.
        priceService.$selectedCurrency
            .dropFirst()
            .sink { [weak self] code in
                self?.currencyChanged(to: code)
            }
            .store(in: &cancellables)
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Lookup

    /// The XMR price at `date` in the selected currency, or nil while
    /// nothing is loaded.
    func price(at date: Date) -> Double? {
        Self.price(at: date, points: points, livePrice: priceService.xmrPrice, now: Date())
    }

    /// What `xmr` was worth at `date` in the selected currency.
    func fiatValue(xmr: Decimal, at date: Date) -> Decimal? {
        guard let price = price(at: date) else { return nil }
        return xmr * Decimal(price)
    }

    /// The price to use for `date`. The live price when the date is within
    /// the last day or newer than the last sample; otherwise the nearest
    /// sample. With no live price the nearest sample stands in. Nil when
    /// there is nothing to answer with.
    nonisolated static func price(at date: Date, points: [PriceHistoryPoint], livePrice: Double?, now: Date) -> Double? {
        let isRecent = date >= now.addingTimeInterval(-liveWindow)
        let isAfterLast = points.last.map { date > $0.timestamp } ?? false
        if isRecent || isAfterLast, let livePrice {
            return livePrice
        }
        return points.nearestByTimestamp(to: date, timestampKeyPath: \.timestamp)?.price
    }

    // MARK: - Refresh

    /// Fetches now when the cache is stale and then once an hour.
    /// Idempotent. Callers gate this on a wallet existing, like
    /// `PriceService.startAutoRefresh`, so no request leaves the device
    /// before the user has one.
    func startAutoRefresh() {
        guard !started else { return }
        started = true

        Task { await refreshIfStale() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.cacheTTL, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshIfStale()
            }
        }
    }

    /// Fetches when the loaded samples are missing or older than the TTL,
    /// for example after the app returns to the foreground.
    func refreshIfStale() async {
        guard started else { return }
        if let fetchedAt, !points.isEmpty,
           Date().timeIntervalSince(fetchedAt) < Self.cacheTTL {
            return
        }
        await fetch(currency: currency)
    }

    private func currencyChanged(to code: String) {
        guard code != currency else { return }
        fetchTask?.cancel()
        fetchTask = nil
        currency = code
        points = []
        fetchedAt = nil
        loadCache(for: code)
        if started {
            Task { await refreshIfStale() }
        }
    }

    /// Joins an in-flight fetch rather than starting a second one.
    private func fetch(currency code: String) async {
        if let inflight = fetchTask {
            await inflight.value
            return
        }
        let task = Task {
            await performFetch(currency: code)
        }
        fetchTask = task
        await task.value
        if fetchTask == task {
            fetchTask = nil
        }
    }

    private func performFetch(currency code: String) async {
        guard let url = Self.historyURL(for: code) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            let parsed = try Self.parse(data)
            // A currency switch while this was in flight cancelled it and
            // the answer belongs to the old currency: drop it.
            guard !Task.isCancelled, code == currency, parsed.currency == Self.sanitized(code),
                  !parsed.points.isEmpty else { return }
            let now = Date()
            points = parsed.points
            fetchedAt = now
            if let cacheDirectory {
                Self.saveCache(PriceHistoryCache(currency: parsed.currency, fetchedAt: now, points: parsed.points), in: cacheDirectory)
            }
        } catch {
            // Keep what is loaded: a stale history beats none.
        }
    }

    // MARK: - Parsing

    nonisolated static func historyURL(for code: String) -> URL? {
        let safe = sanitized(code)
        guard !safe.isEmpty else { return nil }
        return URL(string: "https://monero.one/api/v1/history?currency=\(safe)")
    }

    /// Lowercase ASCII letters only: the code names a file and a query value.
    nonisolated static func sanitized(_ code: String) -> String {
        String(code.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(8))
    }

    /// Turns the API payload into samples. Pure so it can be tested. Drops
    /// short, non-finite and non-positive entries, keeps one sample per
    /// timestamp and sorts ascending.
    nonisolated static func parse(_ data: Data) throws -> (currency: String, points: [PriceHistoryPoint]) {
        let response = try JSONDecoder().decode(PriceHistoryResponse.self, from: data)
        var byTime: [Double: Double] = [:]
        for pair in response.points {
            guard pair.count >= 2 else { continue }
            let seconds = pair[0]
            let price = pair[1]
            guard seconds.isFinite, seconds > 0, price.isFinite, price > 0 else { continue }
            byTime[seconds] = price
        }
        let points = byTime
            .map { PriceHistoryPoint(timestamp: Date(timeIntervalSince1970: $0.key), price: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
        return (sanitized(response.currency), points)
    }

    // MARK: - Disk cache

    /// Application Support/MoneroOne/PriceHistory, beside the hardware
    /// transaction snapshots.
    nonisolated static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoneroOne", isDirectory: true)
            .appendingPathComponent("PriceHistory", isDirectory: true)
    }

    nonisolated static func cacheURL(for code: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(sanitized(code)).json")
    }

    nonisolated static func saveCache(_ cache: PriceHistoryCache, in directory: URL) {
        let url = cacheURL(for: cache.currency, in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func loadCache(for code: String, in directory: URL) -> PriceHistoryCache? {
        let url = cacheURL(for: code, in: directory)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(PriceHistoryCache.self, from: data),
              cache.currency == sanitized(code),
              !cache.points.isEmpty else {
            return nil
        }
        return cache
    }

    private func loadCache(for code: String) {
        guard let cacheDirectory, let cache = Self.loadCache(for: code, in: cacheDirectory) else { return }
        points = cache.points
        fetchedAt = cache.fetchedAt
    }
}
