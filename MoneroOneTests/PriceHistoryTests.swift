import XCTest
@testable import MoneroOne

@MainActor
final class PriceHistoryTests: XCTestCase {

    private static let day: TimeInterval = 24 * 60 * 60

    /// 2020-01-01 00:00 UTC: long before "now", so the live-price window
    /// never applies to these samples.
    private let jan1 = Date(timeIntervalSince1970: 1_577_836_800)
    /// A fixed "now" in September 2026.
    private let now = Date(timeIntervalSince1970: 1_789_900_000)

    /// Three daily samples: 50, 60, 70 on 1, 2 and 3 January 2020.
    private var samples: [PriceHistoryPoint] {
        [
            PriceHistoryPoint(timestamp: jan1, price: 50),
            PriceHistoryPoint(timestamp: jan1.addingTimeInterval(Self.day), price: 60),
            PriceHistoryPoint(timestamp: jan1.addingTimeInterval(2 * Self.day), price: 70),
        ]
    }

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PriceHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    /// A price service that never touches the network: nothing here calls
    /// `startAutoRefresh` or `setCurrency`.
    private func makePriceService(currency: String) -> PriceService {
        let service = PriceService()
        service.selectedCurrency = currency
        return service
    }

    // MARK: - Decoding

    func testDecodesPayloadShape() throws {
        let json = """
        {"currency":"nok","points":[[1400630400,14.71566597439048],[1401235200,13.334089895607685],[1401840000,11.584919929481224]],"timestamp":1789951516641}
        """
        let parsed = try PriceHistoryService.parse(Data(json.utf8))
        XCTAssertEqual(parsed.currency, "nok")
        XCTAssertEqual(parsed.points.count, 3)
        XCTAssertEqual(parsed.points.first?.timestamp, Date(timeIntervalSince1970: 1_400_630_400))
        XCTAssertEqual(parsed.points.first?.price ?? 0, 14.71566597439048, accuracy: 1e-9)
        XCTAssertEqual(parsed.points.last?.timestamp, Date(timeIntervalSince1970: 1_401_840_000))
        XCTAssertEqual(parsed.points.last?.price ?? 0, 11.584919929481224, accuracy: 1e-9)
    }

    func testParseSortsDedupesAndDropsBadPoints() throws {
        // Out of order, a zero price, a duplicate timestamp, a short pair
        // and a negative price.
        let json = """
        {"currency":"USD","points":[[300,3],[100,1],[200,0],[200,2],[400],[500,-1]],"timestamp":0}
        """
        let parsed = try PriceHistoryService.parse(Data(json.utf8))
        XCTAssertEqual(parsed.currency, "usd")
        XCTAssertEqual(parsed.points.map { $0.timestamp.timeIntervalSince1970 }, [100, 200, 300])
        XCTAssertEqual(parsed.points.map(\.price), [1, 2, 3])
    }

    func testParseRejectsWrongShape() {
        XCTAssertThrowsError(try PriceHistoryService.parse(Data("{\"points\":\"nope\"}".utf8)))
        XCTAssertThrowsError(try PriceHistoryService.parse(Data("not json".utf8)))
    }

    // MARK: - Lookup

    func testNearestPicksThePointBeforeTheFirstSample() {
        let tenDaysBefore = jan1.addingTimeInterval(-10 * Self.day)
        XCTAssertEqual(PriceHistoryService.price(at: tenDaysBefore, points: samples, livePrice: 999, now: now), 50)
    }

    func testNearestPicksTheClosestPointBetweenSamples() {
        // 20 hours into day 1 is closer to day 2.
        let lateDay1 = jan1.addingTimeInterval(20 * 60 * 60)
        XCTAssertEqual(PriceHistoryService.price(at: lateDay1, points: samples, livePrice: 999, now: now), 60)
        // 4 hours into day 1 is closer to day 1.
        let earlyDay1 = jan1.addingTimeInterval(4 * 60 * 60)
        XCTAssertEqual(PriceHistoryService.price(at: earlyDay1, points: samples, livePrice: 999, now: now), 50)
        // Exactly on a sample.
        XCTAssertEqual(PriceHistoryService.price(at: jan1.addingTimeInterval(2 * Self.day), points: samples, livePrice: 999, now: now), 70)
    }

    func testAfterTheLastSampleUsesTheLivePrice() {
        // Long before now, but newer than anything in the history.
        let tenDaysAfter = jan1.addingTimeInterval(10 * Self.day)
        XCTAssertEqual(PriceHistoryService.price(at: tenDaysAfter, points: samples, livePrice: 999, now: now), 999)
    }

    func testAfterTheLastSampleWithoutALivePriceUsesTheLastSample() {
        let tenDaysAfter = jan1.addingTimeInterval(10 * Self.day)
        XCTAssertEqual(PriceHistoryService.price(at: tenDaysAfter, points: samples, livePrice: nil, now: now), 70)
    }

    func testRecentDatesUseTheLivePrice() {
        // Samples run right up to now, so only the 24 h window can send a
        // lookup to the live price.
        let recent = [
            PriceHistoryPoint(timestamp: now.addingTimeInterval(-3 * Self.day), price: 10),
            PriceHistoryPoint(timestamp: now.addingTimeInterval(-2 * Self.day), price: 20),
            PriceHistoryPoint(timestamp: now.addingTimeInterval(-Self.day), price: 30),
            PriceHistoryPoint(timestamp: now, price: 40),
        ]
        let anHourAgo = now.addingTimeInterval(-60 * 60)
        XCTAssertEqual(PriceHistoryService.price(at: anHourAgo, points: recent, livePrice: 123, now: now), 123)

        // Older than a day: the sample wins over the live price.
        let twoDaysAgo = now.addingTimeInterval(-2 * Self.day)
        XCTAssertEqual(PriceHistoryService.price(at: twoDaysAgo, points: recent, livePrice: 123, now: now), 20)

        // No live price yet: the nearest sample stands in.
        XCTAssertEqual(PriceHistoryService.price(at: anHourAgo, points: recent, livePrice: nil, now: now), 40)
    }

    func testNilWhenNothingIsLoaded() {
        XCTAssertNil(PriceHistoryService.price(at: jan1, points: [], livePrice: nil, now: now))
        // A live price says nothing about 2020.
        XCTAssertNil(PriceHistoryService.price(at: jan1, points: [], livePrice: 999, now: now))
        // But it does answer for a minute ago.
        XCTAssertEqual(PriceHistoryService.price(at: now.addingTimeInterval(-60), points: [], livePrice: 999, now: now), 999)
    }

    func testFiatValueMultipliesTheAmountByThePrice() {
        let priceService = makePriceService(currency: "usd")

        let empty = PriceHistoryService(priceService: priceService, cacheDirectory: tempDirectory)
        XCTAssertNil(empty.fiatValue(xmr: 1, at: jan1))
        XCTAssertNil(empty.price(at: jan1))

        PriceHistoryService.saveCache(PriceHistoryCache(currency: "usd", fetchedAt: now, points: samples), in: tempDirectory)
        let loaded = PriceHistoryService(priceService: priceService, cacheDirectory: tempDirectory)
        XCTAssertEqual(loaded.price(at: jan1.addingTimeInterval(Self.day)), 60)
        XCTAssertEqual(loaded.fiatValue(xmr: 2, at: jan1.addingTimeInterval(Self.day)), 120)
        XCTAssertEqual(loaded.fiatValue(xmr: Decimal(string: "0.5")!, at: jan1), 25)
    }

    // MARK: - Disk cache

    func testDiskCacheRoundTrip() {
        let cache = PriceHistoryCache(currency: "eur", fetchedAt: now, points: samples)
        PriceHistoryService.saveCache(cache, in: tempDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("eur.json").path))
        XCTAssertEqual(PriceHistoryService.loadCache(for: "eur", in: tempDirectory), cache)
        XCTAssertEqual(PriceHistoryService.loadCache(for: "EUR", in: tempDirectory), cache)
        XCTAssertNil(PriceHistoryService.loadCache(for: "gbp", in: tempDirectory))

        // A new instance picks the cache up before any network call.
        let history = PriceHistoryService(priceService: makePriceService(currency: "eur"), cacheDirectory: tempDirectory)
        XCTAssertEqual(history.currency, "eur")
        XCTAssertEqual(history.points, samples)
        XCTAssertEqual(history.fetchedAt, now)
    }

    func testCacheFileNameAndURLAreSanitized() {
        XCTAssertEqual(PriceHistoryService.cacheURL(for: "../USD", in: tempDirectory).lastPathComponent, "usd.json")
        XCTAssertNil(PriceHistoryService.historyURL(for: "../"))
        XCTAssertEqual(
            PriceHistoryService.historyURL(for: "NOK")?.absoluteString,
            "https://monero.one/api/v1/history?currency=nok"
        )
    }

    // MARK: - Currency switch

    func testCurrencySwitchDropsTheOldPoints() {
        PriceHistoryService.saveCache(PriceHistoryCache(currency: "usd", fetchedAt: now, points: samples), in: tempDirectory)
        let priceService = makePriceService(currency: "usd")
        let history = PriceHistoryService(priceService: priceService, cacheDirectory: tempDirectory)
        XCTAssertEqual(history.currency, "usd")
        XCTAssertEqual(history.points.count, 3)

        priceService.selectedCurrency = "gbp"
        XCTAssertEqual(history.currency, "gbp")
        XCTAssertTrue(history.points.isEmpty, "USD samples must not be shown as GBP")
        XCTAssertNil(history.fetchedAt)
        XCTAssertNil(history.price(at: jan1))

        // Switching to a currency that has a cache loads that cache.
        let eurSamples = [PriceHistoryPoint(timestamp: jan1, price: 45)]
        PriceHistoryService.saveCache(PriceHistoryCache(currency: "eur", fetchedAt: now, points: eurSamples), in: tempDirectory)
        priceService.selectedCurrency = "eur"
        XCTAssertEqual(history.currency, "eur")
        XCTAssertEqual(history.points, eurSamples)
        XCTAssertEqual(history.price(at: jan1), 45)
    }
}
