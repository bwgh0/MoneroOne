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
        FiatCurrency(code: "usd", symbol: "$", flag: "🇺🇸", displayName: String(localized: "US Dollar", comment: "Currency name")),
        FiatCurrency(code: "eur", symbol: "€", flag: "🇪🇺", displayName: String(localized: "Euro", comment: "Currency name")),
        FiatCurrency(code: "gbp", symbol: "£", flag: "🇬🇧", displayName: String(localized: "British Pound", comment: "Currency name")),
        FiatCurrency(code: "cad", symbol: "C$", flag: "🇨🇦", displayName: String(localized: "Canadian Dollar", comment: "Currency name")),
        FiatCurrency(code: "aud", symbol: "A$", flag: "🇦🇺", displayName: String(localized: "Australian Dollar", comment: "Currency name")),
        FiatCurrency(code: "jpy", symbol: "¥", flag: "🇯🇵", displayName: String(localized: "Japanese Yen", comment: "Currency name")),
        FiatCurrency(code: "cny", symbol: "¥", flag: "🇨🇳", displayName: String(localized: "Chinese Yuan", comment: "Currency name")),
        FiatCurrency(code: "try", symbol: "₺", flag: "🇹🇷", displayName: String(localized: "Turkish Lira", comment: "Currency name")),
        FiatCurrency(code: "rub", symbol: "₽", flag: "🇷🇺", displayName: String(localized: "Russian Ruble", comment: "Currency name")),
        FiatCurrency(code: "chf", symbol: "Fr", flag: "🇨🇭", displayName: String(localized: "Swiss Franc", comment: "Currency name")),
        FiatCurrency(code: "brl", symbol: "R$", flag: "🇧🇷", displayName: String(localized: "Brazilian Real", comment: "Currency name")),
        FiatCurrency(code: "inr", symbol: "₹", flag: "🇮🇳", displayName: String(localized: "Indian Rupee", comment: "Currency name")),
        FiatCurrency(code: "krw", symbol: "₩", flag: "🇰🇷", displayName: String(localized: "South Korean Won", comment: "Currency name")),
        FiatCurrency(code: "mxn", symbol: "MX$", flag: "🇲🇽", displayName: String(localized: "Mexican Peso", comment: "Currency name")),
        FiatCurrency(code: "pln", symbol: "zł", flag: "🇵🇱", displayName: String(localized: "Polish Złoty", comment: "Currency name")),
        FiatCurrency(code: "uah", symbol: "₴", flag: "🇺🇦", displayName: String(localized: "Ukrainian Hryvnia", comment: "Currency name")),
        FiatCurrency(code: "nok", symbol: "kr", flag: "🇳🇴", displayName: String(localized: "Norwegian Krone", comment: "Currency name")),
        FiatCurrency(code: "dkk", symbol: "kr", flag: "🇩🇰", displayName: String(localized: "Danish Krone", comment: "Currency name")),
        FiatCurrency(code: "ron", symbol: "lei", flag: "🇷🇴", displayName: String(localized: "Romanian Leu", comment: "Currency name")),
        FiatCurrency(code: "kes", symbol: "KSh", flag: "🇰🇪", displayName: String(localized: "Kenyan Shilling", comment: "Currency name")),
        FiatCurrency(code: "bam", symbol: "KM", flag: "🇧🇦", displayName: String(localized: "Bosnian Mark", comment: "Currency name")),
        FiatCurrency(code: "mad", symbol: "DH", flag: "🇲🇦", displayName: String(localized: "Moroccan Dirham", comment: "Currency name")),
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
