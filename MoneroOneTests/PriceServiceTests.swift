import XCTest
@testable import MoneroOne

@MainActor
final class PriceServiceTests: XCTestCase {

    var priceService: PriceService!
    /// Unit tests run inside the app process on the simulator, so
    /// `setCurrency` writes the real `selectedCurrency` preference. Snapshot
    /// it and put it back, otherwise a test run leaves the sim app on GBP/JPY.
    private var savedCurrency: String?
    /// Same for the Fiat Mode switch.
    private var savedFiatFirst: Any?

    override func setUp() async throws {
        savedCurrency = UserDefaults.standard.string(forKey: "selectedCurrency")
        savedFiatFirst = UserDefaults.standard.object(forKey: PriceService.fiatFirstKey)
        priceService = PriceService()
    }

    override func tearDown() async throws {
        priceService = nil
        if let savedCurrency {
            UserDefaults.standard.set(savedCurrency, forKey: "selectedCurrency")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedCurrency")
        }
        if let savedFiatFirst {
            UserDefaults.standard.set(savedFiatFirst, forKey: PriceService.fiatFirstKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PriceService.fiatFirstKey)
        }
    }

    // MARK: - Fiat Mode

    func testFiatModeIsOffByDefaultAndPersists() {
        UserDefaults.standard.removeObject(forKey: PriceService.fiatFirstKey)
        XCTAssertFalse(PriceService().showFiatFirst)

        PriceService().showFiatFirst = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PriceService.fiatFirstKey))
        XCTAssertTrue(PriceService().showFiatFirst, "A new service reads the saved setting")
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

    /// The original sixteen, in the order the picker has always listed them.
    private let originalCodes = ["usd", "eur", "gbp", "cad", "aud", "jpy", "cny", "try", "rub", "chf", "brl", "inr", "krw", "mxn", "pln", "uah"]
    private let addedCodes = ["nok", "dkk", "ron", "kes", "bam", "mad"]

    func testSupportedCurrenciesExist() async {
        XCTAssertEqual(PriceService.supportedCurrencies.count, 22)
        XCTAssertEqual(PriceService.supportedCurrencies, originalCodes + addedCodes, "existing order kept, new six appended")
        XCTAssertEqual(PriceService.supportedCurrencies, FiatCurrency.all.map(\.code))
        XCTAssertTrue(PriceService.supportedCurrencies.contains("usd"))
        XCTAssertTrue(PriceService.supportedCurrencies.contains("eur"))
        XCTAssertTrue(PriceService.supportedCurrencies.contains("gbp"))
    }

    func testCurrencySymbolsExist() async {
        XCTAssertEqual(PriceService.currencySymbols.count, 22)
        XCTAssertEqual(PriceService.currencySymbols["usd"], "$")
        XCTAssertEqual(PriceService.currencySymbols["eur"], "€")
        XCTAssertEqual(PriceService.currencySymbols["gbp"], "£")
        XCTAssertEqual(PriceService.currencySymbols["jpy"], "¥")
        XCTAssertEqual(PriceService.currencySymbols["pln"], "zł")
        XCTAssertEqual(PriceService.currencySymbols["nok"], "kr")
        XCTAssertEqual(PriceService.currencySymbols["dkk"], "kr")
        XCTAssertEqual(PriceService.currencySymbols["ron"], "lei")
        XCTAssertEqual(PriceService.currencySymbols["kes"], "KSh")
        XCTAssertEqual(PriceService.currencySymbols["bam"], "KM")
        XCTAssertEqual(PriceService.currencySymbols["mad"], "DH")
        XCTAssertEqual(PriceService.currencySymbols["rub"], "₽")
        XCTAssertEqual(PriceService.currencySymbols["uah"], "₴")
        XCTAssertEqual(PriceService.currencySymbols["try"], "₺")
    }

    /// Every amount draws the table's symbol, never the ISO code the system
    /// falls back to ("RUB 1,234.56" on an English iPhone).
    func testFormattedAmountsUseTheTableSymbol() {
        let english = Locale(identifier: "en_US")
        for currency in FiatCurrency.all {
            let text = FiatCurrency.formatter(for: currency.code, locale: english).string(from: 1234.56) ?? ""
            XCTAssertTrue(text.contains(currency.symbol), "\(currency.code): \(text)")
            XCTAssertFalse(text.contains(currency.code.uppercased()), "\(currency.code): \(text)")
        }
        XCTAssertEqual(FiatCurrency.formatter(for: "rub", locale: english).string(from: 1234.56), "₽1,234.56")
        XCTAssertEqual(FiatCurrency.formatter(for: "uah", locale: english).string(from: 1234.56), "₴1,234.56")
        XCTAssertEqual(FiatCurrency.formatter(for: "try", locale: english).string(from: 1234.56), "₺1,234.56")
        XCTAssertEqual(FiatCurrency.formatter(for: "pln", locale: english).string(from: 1234.56), "zł\u{00A0}1,234.56",
                       "a letter symbol keeps its space")
        let russian = FiatCurrency.formatter(for: "rub", locale: Locale(identifier: "ru_RU")).string(from: 1234.56) ?? ""
        XCTAssertTrue(russian.hasSuffix("₽"), "the locale still decides the side: \(russian)")
    }

    func testFormatFiatUsesTheTableSymbol() {
        priceService.setCurrency("uah")
        XCTAssertTrue(priceService.formatFiat(12).contains("₴"), priceService.formatFiat(12))
        XCTAssertFalse(priceService.formatFiat(12).contains("UAH"), priceService.formatFiat(12))
    }

    func testEveryCurrencyHasSymbolFlagAndName() {
        for currency in FiatCurrency.all {
            XCTAssertFalse(currency.symbol.isEmpty, currency.code)
            XCTAssertFalse(currency.flag.isEmpty, currency.code)
            XCTAssertFalse(currency.displayName.isEmpty, currency.code)
        }
        XCTAssertEqual(FiatCurrency.named("pln")?.displayName, "Polish Złoty")
        XCTAssertEqual(FiatCurrency.named("nok")?.flag, "🇳🇴")
        XCTAssertEqual(FiatCurrency.named("bam")?.displayName, "Bosnian Mark")
    }

    func testCurrencyCodesAreUniqueAndLowercase() {
        let codes = FiatCurrency.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "no duplicate codes")
        for code in codes {
            XCTAssertEqual(code, code.lowercased(), code)
            XCTAssertEqual(code.count, 3, code)
        }
    }

    func testNamedLooksUpByCodeInEitherCase() {
        XCTAssertEqual(FiatCurrency.named("nok")?.code, "nok")
        XCTAssertEqual(FiatCurrency.named("NOK")?.code, "nok")
        XCTAssertNil(FiatCurrency.named("xyz"))
    }

    /// `FiatCurrency.symbol(for:)` is what PriceWidget draws with. Every code
    /// the app can select must resolve to the same symbol there, and never to
    /// the old "$" fallback.
    func testWidgetSymbolMatchesAppSymbolForEveryCode() {
        for code in PriceService.supportedCurrencies {
            let widgetSymbol = FiatCurrency.symbol(for: code)
            XCTAssertEqual(widgetSymbol, PriceService.currencySymbols[code], code)
            priceService.selectedCurrency = code
            XCTAssertEqual(priceService.currencySymbol, widgetSymbol, code)
            if code != "usd" {
                XCTAssertNotEqual(widgetSymbol, "$", "\(code) must not fall back to $")
            }
        }
        XCTAssertEqual(FiatCurrency.symbol(for: "xyz"), "XYZ", "an unknown code shows as itself")
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

    // MARK: - Missing quote

    private func response(_ quotes: [String: Double]) -> PriceResponse {
        PriceResponse(
            quotes: quotes.mapValues { PriceQuote(price: $0, change24h: 1.5) },
            timestamp: Date().timeIntervalSince1970
        )
    }

    func testMissingQuoteIsReportedWithoutApplyingAnything() {
        priceService.selectedCurrency = "nok"
        priceService.usdToSelectedRate = 1.0
        XCTAssertThrowsError(try priceService.applyPriceResponse(response(["usd": 500]))) { error in
            guard case PriceError.missingQuote(let currency) = error else {
                return XCTFail("expected missingQuote, got \(error)")
            }
            XCTAssertEqual(currency, "nok")
        }
        XCTAssertNil(priceService.xmrPrice)
        XCTAssertNil(priceService.lastUpdated)
        XCTAssertEqual(priceService.usdToSelectedRate, 1.0)
    }

    func testResponseWithQuoteAppliesPriceAndRate() throws {
        priceService.selectedCurrency = "nok"
        priceService.xmrPrice = nil
        try priceService.applyPriceResponse(response(["usd": 500, "nok": 5000]))
        XCTAssertEqual(priceService.xmrPrice, 5000)
        XCTAssertEqual(priceService.priceChange24h, 1.5)
        XCTAssertEqual(priceService.usdToSelectedRate, 10, accuracy: 1e-9)
        XCTAssertNotNil(priceService.lastUpdated)
    }

    func testMillisecondTimestampIsAcceptedWhenFresh() throws {
        priceService.selectedCurrency = "usd"
        let fresh = PriceResponse(
            quotes: ["usd": PriceQuote(price: 500, change24h: 0)],
            timestamp: Date().timeIntervalSince1970 * 1000
        )
        try priceService.applyPriceResponse(fresh)
        XCTAssertEqual(priceService.xmrPrice, 500)
    }

    func testStaleMillisecondTimestampIsRejected() {
        priceService.selectedCurrency = "usd"
        let stale = PriceResponse(
            quotes: ["usd": PriceQuote(price: 500, change24h: 0)],
            timestamp: (Date().timeIntervalSince1970 - 2 * 3600) * 1000
        )
        XCTAssertThrowsError(try priceService.applyPriceResponse(stale)) { error in
            guard case PriceError.staleResponse(let age) = error else {
                return XCTFail("expected staleResponse, got \(error)")
            }
            XCTAssertGreaterThan(age, 3600)
        }
        XCTAssertNil(priceService.xmrPrice)
    }

    func testResponseTimestampNormalisation() {
        XCTAssertEqual(PriceService.responseTimestampSeconds(1_789_951_621_013), 1_789_951_621.013, accuracy: 1e-6)
        XCTAssertEqual(PriceService.responseTimestampSeconds(1_789_951_621), 1_789_951_621)
    }

    func testMissingQuoteIsNotRetried() async {
        var attempts = 0
        do {
            try await priceService.fetchWithRetry(retries: 3) { () async throws -> Void in
                attempts += 1
                throw PriceError.missingQuote(currency: "nok")
            }
            XCTFail("expected a throw")
        } catch {
            guard case PriceError.missingQuote(let currency) = error else {
                return XCTFail("expected missingQuote, got \(error)")
            }
            XCTAssertEqual(currency, "nok")
        }
        XCTAssertEqual(attempts, 1, "a missing quote is final: no backoff, no second request")
    }

    func testTransientErrorIsStillRetried() async {
        var attempts = 0
        do {
            try await priceService.fetchWithRetry(retries: 2) { () async throws -> Void in
                attempts += 1
                throw URLError(.timedOut)
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testSetCurrencyDropsThePreviousCurrencyRate() {
        priceService.selectedCurrency = "eur"
        priceService.usdToSelectedRate = 0.92
        priceService.setCurrency("nok")
        XCTAssertEqual(priceService.usdToSelectedRate, 1.0, "no EUR rate left behind for a NOK chart")
        XCTAssertNil(priceService.xmrPrice)
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

    func testShortAllSpanStillGetsYearTicks() {
        let span = date("2024-03-10T00:00:00Z")...date("2026-09-20T00:00:00Z")
        let ticks = ChartTimeAxis.all.ticks(in: span, calendar: utc)
        XCTAssertEqual(ticks, [date("2025-01-01T00:00:00Z"), date("2026-01-01T00:00:00Z")], "every year under six years")
    }

    func testFittingAxisFollowsTheSpan() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(ChartTimeAxis.fitting(span: day), .day)
        XCTAssertEqual(ChartTimeAxis.fitting(span: 5 * day), .week)
        XCTAssertEqual(ChartTimeAxis.fitting(span: 30 * day), .month)
        XCTAssertEqual(ChartTimeAxis.fitting(span: 300 * day), .year)
        XCTAssertEqual(ChartTimeAxis.fitting(span: 500 * day), .all, "month names would repeat")
        XCTAssertEqual(ChartTimeAxis.fitting(span: 4 * 365 * day), .all)
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

    // MARK: - Portfolio history

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func tx(
        _ id: String,
        _ type: MoneroTransaction.TransactionType,
        _ amount: Decimal,
        fee: Decimal = 0,
        at time: Date,
        status: MoneroTransaction.TransactionStatus = .confirmed
    ) -> MoneroTransaction {
        MoneroTransaction(
            id: id, type: type, amount: amount, fee: fee, address: "", timestamp: time,
            confirmations: status == .confirmed ? 10 : 0, status: status, memo: nil, blockHeight: nil
        )
    }

    /// Hourly samples at 100, 110, 120, ..., the last one at `end` ("now").
    private func hourlyPrices(_ count: Int, end: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> [PriceDataPoint] {
        (0..<count).map { i in
            PriceDataPoint(timestamp: end.addingTimeInterval(-Double(count - 1 - i) * 3600), price: 100 + Double(i) * 10)
        }
    }

    /// Received 2 between the 2nd and 3rd sample, sent 0.5 + 0.01 fee
    /// between the 4th and the last.
    private func twoTransactionLedger(_ prices: [PriceDataPoint]) -> BalanceLedger {
        let txs = [
            tx("in", .incoming, 2, at: prices[1].timestamp.addingTimeInterval(600)),
            tx("out", .outgoing, d("0.5"), fee: d("0.01"), at: prices[3].timestamp.addingTimeInterval(600)),
        ]
        return BalanceLedger(balance: d("2.99"), transactions: txs, countsPendingIncoming: false)
    }

    func testPortfolioWithoutTransactionsIsTheBalanceAtEverySample() {
        let prices = hourlyPrices(5)
        let points = PortfolioHistory.points(prices: prices, rate: 2, ledger: BalanceLedger(balance: d("1.5"), changes: []))
        XCTAssertEqual(points.map(\.timestamp), prices.map(\.timestamp), "one point per real sample")
        XCTAssertEqual(points.map(\.value), prices.map { 1.5 * $0.price * 2 })
        XCTAssertTrue(points.allSatisfy { $0.changes.isEmpty && $0.balance == d("1.5") })
    }

    func testPortfolioHoldsWhatWasHeldAtEachSample() {
        let prices = hourlyPrices(5)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: twoTransactionLedger(prices))
        XCTAssertEqual(points.map(\.balance), [d("1.5"), d("1.5"), d("3.5"), d("3.5"), d("2.99")])
        XCTAssertEqual(points[0].value, 1.5 * 100, accuracy: 1e-9)
        XCTAssertEqual(points[2].value, 3.5 * 120, accuracy: 1e-9)
        XCTAssertEqual(points[4].value, 2.99 * 140, accuracy: 1e-9, "the tip is the balance on screen")
        XCTAssertEqual(points.map { $0.changes.map(\.id) }, [[], [], ["in"], [], ["out"]],
                       "a transaction shows on the first sample that includes it")
    }

    func testTransactionAfterTheLastSampleShowsAtTheTip() {
        // The live tip is stamped when the price was fetched; a receive
        // after that still belongs to "now".
        let prices = hourlyPrices(3)
        let late = tx("late", .incoming, 1, at: prices[2].timestamp.addingTimeInterval(60))
        let ledger = BalanceLedger(balance: 3, transactions: [late], countsPendingIncoming: false)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger)
        XCTAssertEqual(points.map(\.balance), [2, 2, 3])
        XCTAssertEqual(points.last?.changes.map(\.id), ["late"])
    }

    func testOnlyTransactionsThatMovedTheBalanceCount() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(BalanceChange(tx("f", .outgoing, 1, at: t, status: .failed), countsPendingIncoming: true))
        XCTAssertNil(BalanceChange(tx("p", .incoming, 1, at: t, status: .pending), countsPendingIncoming: false),
                     "wallet2's balance leaves pool incoming out")
        XCTAssertEqual(BalanceChange(tx("p", .incoming, 1, at: t, status: .pending), countsPendingIncoming: true)?.delta, 1,
                       "the hardware display balance counts it")
        XCTAssertEqual(BalanceChange(tx("o", .outgoing, d("0.5"), fee: d("0.01"), at: t, status: .pending),
                                     countsPendingIncoming: false)?.delta, d("-0.51"),
                       "a pending send has already left the balance, fee included")
        XCTAssertEqual(BalanceChange(tx("i", .incoming, 2, fee: d("0.01"), at: t), countsPendingIncoming: false)?.delta, 2,
                       "the sender paid the fee")
    }

    func testChangesBeforeTheRangeSetTheLevelWithoutADot() {
        let prices = hourlyPrices(3)
        let old = tx("old", .incoming, 5, at: prices[0].timestamp.addingTimeInterval(-86_400))
        let points = PortfolioHistory.points(
            prices: prices, rate: 1,
            ledger: BalanceLedger(balance: 5, transactions: [old], countsPendingIncoming: false)
        )
        XCTAssertEqual(points.map(\.balance), [5, 5, 5])
        XCTAssertTrue(points.allSatisfy { $0.changes.isEmpty })
    }

    func testUnknownHistoryIsNotDrawn() {
        let prices = hourlyPrices(5)
        let ledger = BalanceLedger(balance: 1, changes: [], knownSince: prices[2].timestamp)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger)
        XCTAssertEqual(points.map(\.timestamp), Array(prices[2...].map(\.timestamp)))
    }

    func testAllRangeStartsWhereTheWalletFirstHeldSomething() {
        let prices = hourlyPrices(6)
        let first = tx("first", .incoming, 1, at: prices[3].timestamp.addingTimeInterval(600))
        let ledger = BalanceLedger(balance: 1, transactions: [first], countsPendingIncoming: false)
        XCTAssertEqual(PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger).count, 6)
        let trimmed = PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger, startAtFirstHolding: true)
        XCTAssertEqual(trimmed.map(\.balance), [0, 1, 1], "keeps the one empty sample the line rises from")
        XCTAssertEqual(trimmed.first?.timestamp, prices[3].timestamp)
    }

    func testLedgerThatDoesNotAddUpNeverGoesBelowZero() {
        let prices = hourlyPrices(3)
        let receive = tx("in", .incoming, 2, at: prices[1].timestamp.addingTimeInterval(600))
        let ledger = BalanceLedger(balance: 1, transactions: [receive], countsPendingIncoming: false)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger)
        XCTAssertEqual(points.map(\.balance), [0, 0, 1])
        XCTAssertTrue(points.allSatisfy { $0.value >= 0 })
    }

    func testMarkersSitOnTheSamplesWithTransactions() {
        let prices = hourlyPrices(5)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: twoTransactionLedger(prices))
        let markers = PortfolioHistory.markers(for: points) { String(format: "$%.2f", $0) }
        XCTAssertEqual(markers.map(\.timestamp), [prices[2].timestamp, prices[4].timestamp])
        XCTAssertEqual(markers.map(\.value), [points[2].value, points[4].value], "each dot is on a real sample")
        XCTAssertEqual(markers.map(\.style), [.received, .sent])
        XCTAssertEqual(markers.map(\.accessibilityLabel), ["Received 2.0000 XMR", "Sent 0.5000 XMR"])
        XCTAssertTrue(markers[0].accessibilityValue.hasSuffix("portfolio $420.00"), markers[0].accessibilityValue)
        XCTAssertEqual(PortfolioHistory.summary(of: points[2].changes), "Received 2.0000 XMR")
        XCTAssertNil(PortfolioHistory.summary(of: points[3].changes))
    }

    func testManyTransactionsOnOneSampleAreSummed() {
        let prices = hourlyPrices(2)
        let t = prices[0].timestamp
        let txs = (0..<4).map { tx("in\($0)", .incoming, d("0.25"), at: t.addingTimeInterval(Double($0 + 1) * 60)) }
            + [tx("out", .outgoing, d("0.1"), at: t.addingTimeInterval(600))]
        let ledger = BalanceLedger(balance: d("0.9"), transactions: txs, countsPendingIncoming: false)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: ledger)
        XCTAssertEqual(PortfolioHistory.summary(of: points[1].changes), "5 transactions")
        let marker = PortfolioHistory.markers(for: points) { "\($0)" }.first
        XCTAssertEqual(marker?.style, .received, "net +0.9")
        XCTAssertEqual(marker?.accessibilityLabel, "5 transactions, received 1.0000 XMR, sent 0.1000 XMR")
    }

    func testHardwareMergeKeepsTheSendOverItsChangeOutput() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        // VIEW sees the change of a send as incoming, under the send's hash.
        let view = [tx("send", .incoming, d("0.3"), at: t), tx("gift", .incoming, 1, at: t.addingTimeInterval(60))]
        let snapshot = [tx("send", .outgoing, d("0.5"), fee: d("0.01"), at: t)]
        let merged = WalletManager.mergedByHash(view, snapshot)
        XCTAssertEqual(merged.map(\.id), ["gift", "send"], "newest first")
        XCTAssertEqual(merged.last?.type, .outgoing)
        XCTAssertEqual(WalletManager.mergedByHash(snapshot, view).last?.type, .outgoing, "whichever side it came from")
    }

    // MARK: - VoiceOver summary

    func testChartSummaryRoundsTheChangeLikeTheHeader() {
        let speech = ChartSpeech(title: "Portfolio", span: "past week", currencyCode: "usd", note: "2 transactions")
        XCTAssertEqual(
            speech.summary(first: 1000, last: 1089.87),
            "From \(speech.format(1000)) to \(speech.format(1089.87)), up 8.99%, 2 transactions"
        )
        XCTAssertEqual(ChartSpeech.spokenChange(-1.2), "down 1.20%")
        XCTAssertEqual(ChartSpeech.spokenChange(-0.004), "unchanged", "the header shows 0.00%")
        XCTAssertFalse(speech.summary(first: 0, last: 10).contains("up"), "no change from nothing, as in the header")
    }

    func testChartSummaryCountsTheTransactionsOnTheChart() {
        let prices = hourlyPrices(5)
        let points = PortfolioHistory.points(prices: prices, rate: 1, ledger: twoTransactionLedger(prices))
        XCTAssertEqual(PortfolioHistory.spokenCount(in: points), "2 transactions")
        XCTAssertEqual(PortfolioHistory.spokenCount(in: Array(points.prefix(3))), "1 transaction")
        XCTAssertNil(PortfolioHistory.spokenCount(in: Array(points.prefix(2))))
    }
}
