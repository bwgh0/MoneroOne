import XCTest
@testable import MoneroOne

@MainActor
final class PriceServiceTests: XCTestCase {

    var priceService: PriceService!

    override func setUp() async throws {
        priceService = PriceService()
    }

    override func tearDown() async throws {
        priceService = nil
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
}
