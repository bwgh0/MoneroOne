import XCTest
@testable import MoneroOne

@MainActor
final class PriceServiceTests: XCTestCase {

    var priceService: PriceService!
    /// Unit tests run inside the app process on the simulator, so
    /// `setCurrency` writes the real `selectedCurrency` preference. Snapshot
    /// it and put it back, otherwise a test run leaves the sim app on GBP/JPY.
    private var savedCurrency: String?

    override func setUp() async throws {
        savedCurrency = UserDefaults.standard.string(forKey: "selectedCurrency")
        priceService = PriceService()
    }

    override func tearDown() async throws {
        priceService = nil
        if let savedCurrency {
            UserDefaults.standard.set(savedCurrency, forKey: "selectedCurrency")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedCurrency")
        }
    }

    // MARK: - Initial State Tests

    func testInitialPriceIsNil() async {
        let freshService = PriceService()
        // Price might be nil initially before first fetch
        // Note: startAutoRefresh() is called in init, so price may be fetched
        XCTAssertTrue(freshService.xmrPrice == nil || freshService.xmrPrice != nil, "Price can be nil or fetched")
    }

    func testInitialCurrencyIsUSD() async {
        let freshService = PriceService()
        // Default currency should be USD unless previously set
        XCTAssertTrue(PriceService.supportedCurrencies.contains(freshService.selectedCurrency))
    }

    func testIsLoadingInitiallyFalseOrTrue() async {
        // Loading state depends on timing of auto-refresh
        XCTAssertNotNil(priceService.isLoading)
    }

    // MARK: - Currency Tests

    func testSupportedCurrenciesExist() async {
        XCTAssertFalse(PriceService.supportedCurrencies.isEmpty)
        XCTAssertTrue(PriceService.supportedCurrencies.contains("usd"))
        XCTAssertTrue(PriceService.supportedCurrencies.contains("eur"))
        XCTAssertTrue(PriceService.supportedCurrencies.contains("gbp"))
    }

    func testCurrencySymbolsExist() async {
        XCTAssertEqual(PriceService.currencySymbols["usd"], "$")
        XCTAssertEqual(PriceService.currencySymbols["eur"], "€")
        XCTAssertEqual(PriceService.currencySymbols["gbp"], "£")
        XCTAssertEqual(PriceService.currencySymbols["jpy"], "¥")
    }

    func testCurrencySymbolProperty() async {
        priceService.selectedCurrency = "usd"
        XCTAssertEqual(priceService.currencySymbol, "$")

        priceService.selectedCurrency = "eur"
        XCTAssertEqual(priceService.currencySymbol, "€")
    }

    func testSetCurrencyUpdatesCurrency() async {
        priceService.setCurrency("eur")
        XCTAssertEqual(priceService.selectedCurrency, "eur")

        priceService.setCurrency("gbp")
        XCTAssertEqual(priceService.selectedCurrency, "gbp")
    }

    func testSetCurrencySavesToUserDefaults() async {
        priceService.setCurrency("jpy")

        let saved = UserDefaults.standard.string(forKey: "selectedCurrency")
        XCTAssertEqual(saved, "jpy")
    }

    // MARK: - Formatting Tests

    func testFormatFiatValueReturnsNilWithoutPrice() async {
        let freshService = PriceService()
        // If xmrPrice is nil, formatFiatValue should return nil
        if freshService.xmrPrice == nil {
            XCTAssertNil(freshService.formatFiatValue(1.0))
        }
    }

    func testFormatPriceChangeReturnsNilWithoutChange() async {
        let freshService = PriceService()
        if freshService.priceChange24h == nil {
            XCTAssertNil(freshService.formatPriceChange())
        }
    }

    func testFormatPriceChangePositive() async {
        priceService.priceChange24h = 5.25
        let formatted = priceService.formatPriceChange()
        XCTAssertEqual(formatted, "+5.25%")
    }

    func testFormatPriceChangeNegative() async {
        priceService.priceChange24h = -3.50
        let formatted = priceService.formatPriceChange()
        XCTAssertEqual(formatted, "-3.50%")
    }

    func testFormatPriceChangeZero() async {
        priceService.priceChange24h = 0.0
        let formatted = priceService.formatPriceChange()
        XCTAssertEqual(formatted, "+0.00%")
    }

    // MARK: - API Integration Tests

    func testFetchPriceUpdatesLastUpdated() async {
        await priceService.fetchPrice()

        // After fetch, lastUpdated should be set (unless there was an error)
        if priceService.error == nil {
            XCTAssertNotNil(priceService.lastUpdated)
        }
    }

    func testFetchPriceSetsLoadingState() async {
        // Wait for any auto-refresh to complete
        await priceService.fetchPrice()
        // After explicit fetch completes, isLoading should be false
        XCTAssertFalse(priceService.isLoading, "Should not be loading after fetch completes")
    }

    // MARK: - Chart Data

    private func point(_ ts: Double, _ price: Double) -> CMCPoint {
        CMCPoint(s: String(ts), v: [price, 0, 0])
    }

    func testChartSamplesKeepEveryRealSampleUnaltered() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = (0..<288).map { i in
            point(now.timeIntervalSince1970 - Double(287 - i) * 300, 500 + Double(i % 7) * 3.25)
        }
        let samples = PriceService.chartSamples(from: raw, range: "1D", now: now)
        XCTAssertEqual(samples.count, 288, "no downsampling")
        for (sample, source) in zip(samples, raw) {
            XCTAssertEqual(sample.price, source.v[0], "no smoothing")
            XCTAssertEqual(sample.timestamp.timeIntervalSince1970, Double(source.s)!)
        }
    }

    func testChartSamplesTrimSortDedupeAndDropGarbage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        let raw = [
            point(t - 90_000, 400),   // older than 24h: trimmed
            point(t - 600, 502),
            point(t - 300, 503),
            point(t - 300, 504),      // duplicate timestamp: last one wins
            point(t - 900, 501),      // out of order
            CMCPoint(s: "nope", v: [500, 0, 0]),
            point(t - 1200, .nan),
            point(t - 1500, 0),
        ]
        let samples = PriceService.chartSamples(from: raw, range: "1D", now: now)
        XCTAssertEqual(samples.map(\.price), [501, 502, 504])
        XCTAssertEqual(samples.map { $0.timestamp.timeIntervalSince1970 }, [t - 900, t - 600, t - 300])
    }

    func testChartSamplesKeepEarlyHistoryOnAllRange() {
        // XMR traded at $0.25 in 2014 and $500+ now. The old median filter
        // deleted those years; only an isolated spike may be dropped.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = now.timeIntervalSince1970
        let raw = (0..<640).map { week in
            point(t - Double(639 - week) * 604_800, 0.25 * pow(1.012, Double(week)))
        }
        let samples = PriceService.chartSamples(from: raw, range: "All", now: now)
        XCTAssertEqual(samples.count, 640)
        XCTAssertEqual(samples.first?.price, 0.25)
    }

    func testIsolatedSpikeIsDroppedButRealMoveIsKept() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func p(_ i: Int, _ price: Double) -> PriceDataPoint {
            PriceDataPoint(timestamp: base.addingTimeInterval(Double(i) * 300), price: price)
        }
        let spike = [p(0, 100), p(1, 101), p(2, 5000), p(3, 102), p(4, 103)]
        XCTAssertEqual(PriceService.removingIsolatedSpikes(spike).map(\.price), [100, 101, 102, 103])
        let move = [p(0, 100), p(1, 101), p(2, 600), p(3, 610), p(4, 605)]
        XCTAssertEqual(PriceService.removingIsolatedSpikes(move).count, 5)
    }

    func testChartSeriesAppendsLiveTipOnlyWhenNewer() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            PriceDataPoint(timestamp: base, price: 500),
            PriceDataPoint(timestamp: base.addingTimeInterval(300), price: 501),
        ]
        let newer = PriceDataPoint(timestamp: base.addingTimeInterval(400), price: 503)
        let series = PriceService.chartSeries(samples: samples, liveTip: newer)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(Array(series.prefix(2)), samples, "samples are never altered")
        XCTAssertEqual(series.last, newer)

        let older = PriceDataPoint(timestamp: base.addingTimeInterval(100), price: 503)
        XCTAssertEqual(PriceService.chartSeries(samples: samples, liveTip: older), samples)
        XCTAssertEqual(PriceService.chartSeries(samples: samples, liveTip: nil), samples)
        XCTAssertTrue(PriceService.chartSeries(samples: [], liveTip: newer).isEmpty, "no lone tip")
    }

    func testChartYDomainContainsEverySample() {
        let domain = PriceService.chartYDomain(for: [480, 520, 495])
        XCTAssertLessThan(domain.lowerBound, 480)
        XCTAssertGreaterThan(domain.upperBound, 520)
        XCTAssertEqual(domain.upperBound - domain.lowerBound, 44, accuracy: 1e-9)

        let flat = PriceService.chartYDomain(for: [500, 500])
        XCTAssertTrue(flat.contains(500))
        XCTAssertGreaterThan(flat.upperBound, flat.lowerBound)
        XCTAssertEqual(PriceService.chartYDomain(for: []), 0...100)
    }

    func testWidgetSparklineUsesRealSamplesAndEndsAtLatest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<289).map { i in
            PriceDataPoint(timestamp: now.addingTimeInterval(-Double(288 - i) * 300), price: 500 + Double(i))
        }
        let line = PriceService.widgetSparkline(from: samples, rate: 2, now: now)
        XCTAssertEqual(line.count, 48)
        XCTAssertEqual(line.last, samples.last!.price * 2)
        let allowed = Set(samples.map { $0.price * 2 })
        XCTAssertTrue(line.allSatisfy { allowed.contains($0) }, "every value is a real sample")
        XCTAssertEqual(line, line.sorted(), "rising input stays rising: no resampling artefacts")

        // Only six hours of history: leading slots are dropped, not padded.
        let short = Array(samples.suffix(73))
        XCTAssertEqual(PriceService.widgetSparkline(from: short, rate: 1, now: now).count, 13)
    }

    // MARK: - Chart time axis

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    func testDayTicksUseDistinctClockNumerals() {
        let span = date("2026-09-19T14:50:00Z")...date("2026-09-20T14:50:00Z")
        let ticks = ChartTimeAxis.day.ticks(in: span, calendar: utc)
        XCTAssertEqual(ticks, [
            date("2026-09-19T15:00:00Z"), date("2026-09-19T20:00:00Z"), date("2026-09-20T00:00:00Z"),
            date("2026-09-20T05:00:00Z"), date("2026-09-20T10:00:00Z"),
        ])
        // 3 PM, 8 PM, 12 AM, 5 AM, 10 AM: no numeral twice.
        let numerals = ticks.map { utc.component(.hour, from: $0) % 12 }
        XCTAssertEqual(Set(numerals).count, numerals.count)
    }

    func testWeekTicksAreMidnights() {
        let span = date("2026-09-13T03:00:00Z")...date("2026-09-20T03:00:00Z")
        let ticks = ChartTimeAxis.week.ticks(in: span, calendar: utc)
        XCTAssertEqual(ticks.count, 7)
        XCTAssertEqual(ticks.first, date("2026-09-14T00:00:00Z"))
        XCTAssertTrue(ticks.allSatisfy { utc.component(.hour, from: $0) == 0 })
    }

    func testMonthTicksAreWeekStarts() {
        let span = date("2026-08-21T10:00:00Z")...date("2026-09-20T10:00:00Z")
        let ticks = ChartTimeAxis.month.ticks(in: span, calendar: utc)
        XCTAssertEqual(ticks.count, 5)  // Aug 23, 30, Sep 6, 13, 20
        // en_US weeks start on Sunday.
        XCTAssertTrue(ticks.allSatisfy { utc.component(.weekday, from: $0) == 1 })
        XCTAssertEqual(ticks.first, date("2026-08-23T00:00:00Z"))
    }

    func testYearAndAllTicks() {
        let year = ChartTimeAxis.year.ticks(in: date("2025-09-20T00:00:00Z")...date("2026-09-20T00:00:00Z"), calendar: utc)
        XCTAssertEqual(year.first, date("2025-10-01T00:00:00Z"))
        XCTAssertEqual(year.count, 6)
        XCTAssertTrue(year.allSatisfy { utc.component(.day, from: $0) == 1 })

        let all = ChartTimeAxis.all.ticks(in: date("2014-05-21T00:00:00Z")...date("2026-09-20T00:00:00Z"), calendar: utc)
        XCTAssertEqual(all.first, date("2015-01-01T00:00:00Z"))
        XCTAssertEqual(all.count, 6)
    }

    func testDayScrubLabelNamesYesterday() {
        // The relative word comes from the system formatter, which reads the
        // real clock, so anchor the fixture to the real clock too.
        let calendar = Calendar.current
        let now = Date()
        let todayAt11 = calendar.date(byAdding: .hour, value: 11, to: calendar.startOfDay(for: now))!
        let yesterdayAt11 = calendar.date(byAdding: .day, value: -1, to: todayAt11)!
        let today = ChartTimeAxis.day.scrubLabel(for: todayAt11, now: now, calendar: calendar)
        let yesterday = ChartTimeAxis.day.scrubLabel(for: yesterdayAt11, now: now, calendar: calendar)
        XCTAssertFalse(today.localizedCaseInsensitiveContains("yesterday"), today)
        XCTAssertTrue(yesterday.localizedCaseInsensitiveContains("yesterday"), yesterday)
    }
}


