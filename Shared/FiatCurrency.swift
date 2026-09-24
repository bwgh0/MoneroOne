import Foundation

/// A fiat currency the price API can quote XMR in. This is the one table for
/// the app and the widget, so the symbol a widget draws is the symbol the app
/// draws and the picker lists exactly what the price service accepts.
public struct FiatCurrency: Hashable, Identifiable, Sendable {
    /// ISO 4217 code in lowercase: the key the price API quotes by and the
    /// value the app stores in `selectedCurrency`.
    public let code: String
    /// What is drawn before an amount.
    public let symbol: String
    public let flag: String
    public let displayName: String

    public var id: String { code }

    /// Every supported currency, in the order the picker lists them.
    public static let all: [FiatCurrency] = [
        FiatCurrency(code: "usd", symbol: "$", flag: "🇺🇸", displayName: "US Dollar"),
        FiatCurrency(code: "eur", symbol: "€", flag: "🇪🇺", displayName: "Euro"),
        FiatCurrency(code: "gbp", symbol: "£", flag: "🇬🇧", displayName: "British Pound"),
        FiatCurrency(code: "cad", symbol: "C$", flag: "🇨🇦", displayName: "Canadian Dollar"),
        FiatCurrency(code: "aud", symbol: "A$", flag: "🇦🇺", displayName: "Australian Dollar"),
        FiatCurrency(code: "jpy", symbol: "¥", flag: "🇯🇵", displayName: "Japanese Yen"),
        FiatCurrency(code: "cny", symbol: "¥", flag: "🇨🇳", displayName: "Chinese Yuan"),
        FiatCurrency(code: "try", symbol: "₺", flag: "🇹🇷", displayName: "Turkish Lira"),
        FiatCurrency(code: "rub", symbol: "₽", flag: "🇷🇺", displayName: "Russian Ruble"),
        FiatCurrency(code: "chf", symbol: "Fr", flag: "🇨🇭", displayName: "Swiss Franc"),
        FiatCurrency(code: "brl", symbol: "R$", flag: "🇧🇷", displayName: "Brazilian Real"),
        FiatCurrency(code: "inr", symbol: "₹", flag: "🇮🇳", displayName: "Indian Rupee"),
        FiatCurrency(code: "krw", symbol: "₩", flag: "🇰🇷", displayName: "South Korean Won"),
        FiatCurrency(code: "mxn", symbol: "MX$", flag: "🇲🇽", displayName: "Mexican Peso"),
        FiatCurrency(code: "pln", symbol: "zł", flag: "🇵🇱", displayName: "Polish Złoty"),
        FiatCurrency(code: "uah", symbol: "₴", flag: "🇺🇦", displayName: "Ukrainian Hryvnia"),
        FiatCurrency(code: "nok", symbol: "kr", flag: "🇳🇴", displayName: "Norwegian Krone"),
        FiatCurrency(code: "dkk", symbol: "kr", flag: "🇩🇰", displayName: "Danish Krone"),
        FiatCurrency(code: "ron", symbol: "lei", flag: "🇷🇴", displayName: "Romanian Leu"),
        FiatCurrency(code: "kes", symbol: "KSh", flag: "🇰🇪", displayName: "Kenyan Shilling"),
        FiatCurrency(code: "bam", symbol: "KM", flag: "🇧🇦", displayName: "Bosnian Mark"),
        FiatCurrency(code: "mad", symbol: "DH", flag: "🇲🇦", displayName: "Moroccan Dirham"),
    ]

    /// The currency for a code, in either case, or nil when this build does
    /// not know the code.
    public static func named(_ code: String) -> FiatCurrency? {
        byCode[code.lowercased()]
    }

    /// The symbol to draw before an amount in `code`. A code this build does
    /// not know shows as itself rather than as a wrong "$".
    public static func symbol(for code: String) -> String {
        named(code)?.symbol ?? code.uppercased()
    }

    /// A currency formatter for `code` that draws this table's symbol.
    /// NumberFormatter's own symbol comes from the phone's language and falls
    /// back to the ISO code: an English iPhone showed "RUB 1,234.56" where
    /// the picker shows "₽". Placement and spacing still follow `locale`
    /// ("₽1,234.56" in English, "1 234,56 ₽" in Russian).
    public static func formatter(for code: String, locale: Locale = .current) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code.uppercased()
        formatter.currencySymbol = symbol(for: code)
        return formatter
    }

    private static let byCode: [String: FiatCurrency] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
}
