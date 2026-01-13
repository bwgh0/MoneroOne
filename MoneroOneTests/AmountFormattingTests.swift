import XCTest
@testable import MoneroOne

final class AmountFormattingTests: XCTestCase {

    // MARK: - XMR Formatting Tests

    func testFormatWholeNumber() {
        let formatter = XMRFormatter()
        let result = formatter.format(Decimal(1))

        XCTAssertEqual(result, "1.0000", "Should format with 4 decimal places minimum")
    }

    func testFormatSmallAmount() {
        let formatter = XMRFormatter()
        let result = formatter.format(Decimal(string: "0.000000000001")!) // 1 piconero

        XCTAssertFalse(result.isEmpty, "Should format small amounts")
    }

    func testFormatLargeAmount() {
        let formatter = XMRFormatter()
        let result = formatter.format(Decimal(1000000))

        XCTAssertTrue(result.contains("1"), "Should handle large amounts")
    }

    func testFormatZero() {
        let formatter = XMRFormatter()
        let result = formatter.format(Decimal(0))

        XCTAssertEqual(result, "0.0000", "Zero should format as 0.0000")
    }

    func testFormatWithManyDecimals() {
        let formatter = XMRFormatter()
        let result = formatter.format(Decimal(string: "1.123456789012")!)

        // Should not exceed 12 decimal places
        let parts = result.split(separator: ".")
        if parts.count == 2 {
            XCTAssertLessThanOrEqual(parts[1].count, 12, "Should not exceed 12 decimal places")
        }
    }

    // MARK: - Piconero Conversion Tests

    func testPiconeroToXMRConversion() {
        let piconero: UInt64 = 1_000_000_000_000 // 1 XMR
        let coinRate: Decimal = 1_000_000_000_000

        let xmr = Decimal(piconero) / coinRate

        XCTAssertEqual(xmr, Decimal(1), "1 trillion piconero should equal 1 XMR")
    }

    func testSmallPiconeroConversion() {
        let piconero: UInt64 = 1 // Smallest unit
        let coinRate: Decimal = 1_000_000_000_000

        let xmr = Decimal(piconero) / coinRate

        XCTAssertEqual(xmr, Decimal(string: "0.000000000001"), "1 piconero should be 10^-12 XMR")
    }

    func testXMRToPiconeroConversion() {
        let xmr = Decimal(string: "1.5")!
        let coinRate: Decimal = 1_000_000_000_000

        let piconero = Int((xmr * coinRate) as NSDecimalNumber)

        XCTAssertEqual(piconero, 1_500_000_000_000, "1.5 XMR should be 1.5 trillion piconero")
    }
}

// MARK: - Helper

/// Simple XMR formatter for testing
struct XMRFormatter {
    func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}
