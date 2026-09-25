import Foundation

/// A Monero payment request, `monero:<address>?tx_amount=<xmr>`: the format
/// wallet2's `parse_uri` reads and Monero wallets put in links and QR codes.
///
/// There are two readers. `parseLink` is strict. It reads a URL that another
/// app opened us with, so anything it cannot honor exactly is an error the
/// user sees. `parseScanned` is for the camera: it also takes a bare address,
/// and it keeps the address when the rest of the code is damaged, as the
/// scanner always did.
///
/// `recipient_name` and `tx_description` are read past and dropped. Both are
/// free text from whoever made the link, and a wallet that shows them lets a
/// stranger's link call itself "Monero One Support".
struct MoneroPaymentURI: Equatable {
    let address: String
    /// Plain decimal XMR ("0.25"), nil when the request names no amount.
    let amount: String?

    enum ParseError: Error, Equatable {
        case notMoneroURI
        case invalidAddress
        case malformedParameter
        case duplicateParameter(String)
        case invalidAmount
        case paymentIDUnsupported

        /// Copy for the alert that refuses a link.
        var message: String {
            switch self {
            case .notMoneroURI, .malformedParameter, .duplicateParameter:
                return String(localized: "This is not a valid Monero payment link.")
            case .invalidAddress:
                return String(localized: "This link has no valid Monero address.")
            case .invalidAmount:
                return String(localized: "The amount in this link is not a valid XMR amount.")
            case .paymentIDUnsupported:
                return String(localized: "This link uses a payment ID, which Monero no longer supports. Ask the recipient for a subaddress or an integrated address.")
            }
        }
    }

    /// Largest amount wallet2 can hold: UInt64.max piconero.
    static let maximumAmount = Decimal(string: "18446744.073709551615", locale: posix)!

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let scheme = "monero:"
    private static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    // MARK: - Readers

    /// Reads a link another app opened us with. Follows wallet2's rules:
    /// every parameter is `key=value`, no key twice, the amount parses as
    /// XMR, unknown keys are ignored. A payment ID is refused: current
    /// wallets cannot send one, and dropping it would lose the payment.
    static func parseLink(_ raw: String) throws -> MoneroPaymentURI {
        guard let rest = stripScheme(raw) else { throw ParseError.notMoneroURI }
        let (address, query) = split(rest)
        guard isAddressShaped(address) else { throw ParseError.invalidAddress }

        var seen: Set<String> = []
        var amount: String?
        for segment in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = segment.firstIndex(of: "=") else { throw ParseError.malformedParameter }
            let key = String(segment[..<equals])
            let value = String(segment[segment.index(after: equals)...])
            guard !key.isEmpty else { throw ParseError.malformedParameter }
            guard seen.insert(key).inserted else { throw ParseError.duplicateParameter(key) }

            switch key {
            case "tx_amount":
                guard let decoded = value.removingPercentEncoding,
                      let xmr = parseAmount(decoded) else { throw ParseError.invalidAmount }
                amount = xmr > 0 ? plain(xmr) : nil
            case "tx_payment_id":
                throw ParseError.paymentIDUnsupported
            default:
                // recipient_name, tx_description and unknown keys.
                continue
            }
        }
        return MoneroPaymentURI(address: address, amount: amount)
    }

    /// Reads a scanned QR code. Takes a `monero:` URI or a bare address;
    /// keeps the address and drops a bad amount instead of failing, and
    /// never rejects anything. The send flow checks the address after.
    static func parseScanned(_ raw: String) -> MoneroPaymentURI {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rest = stripScheme(trimmed) else {
            return MoneroPaymentURI(address: trimmed, amount: nil)
        }
        let (address, query) = split(rest)

        var amount: String?
        for segment in query.split(separator: "&") {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == "tx_amount",
                  let decoded = String(pair[1]).removingPercentEncoding,
                  let xmr = parseAmount(decoded), xmr > 0 else { continue }
            amount = plain(xmr)
            break
        }
        return MoneroPaymentURI(address: address, amount: amount)
    }

    // MARK: - Pieces

    /// The text after `monero:` (any case) and an optional `//`, or nil
    /// when the string has another scheme or none.
    private static func stripScheme(_ raw: String) -> Substring? {
        guard raw.count > scheme.count,
              raw.prefix(scheme.count).lowercased() == scheme else { return nil }
        var rest = raw.dropFirst(scheme.count)
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        return rest
    }

    private static func split(_ rest: Substring) -> (address: String, query: Substring) {
        guard let question = rest.firstIndex(of: "?") else { return (String(rest), "") }
        return (String(rest[..<question]), rest[rest.index(after: question)...])
    }

    /// Base58 and the length of a standard or subaddress (95) or an
    /// integrated address (106). The network check needs wallet2 and runs
    /// in `WalletManager.openPaymentLink`.
    static func isAddressShaped(_ address: String) -> Bool {
        (address.count == 95 || address.count == 106) && address.allSatisfy { base58.contains($0) }
    }

    /// wallet2's `parse_amount`: digits with at most one point, at most 12
    /// decimals once trailing zeros are gone, no sign, no exponent, no
    /// grouping. ".5" and "1." are accepted, as wallet2 accepts them.
    static func parseAmount(_ raw: String) -> Decimal? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = parts[0]
        var fraction = parts.count == 2 ? parts[1] : ""
        guard isDigits(whole), isDigits(fraction), !(whole.isEmpty && fraction.isEmpty) else { return nil }
        while fraction.hasSuffix("0") { fraction = fraction.dropLast() }
        guard fraction.count <= 12 else { return nil }

        let text = "\(whole.isEmpty ? "0" : whole).\(fraction.isEmpty ? "0" : fraction)"
        guard let value = Decimal(string: text, locale: posix), value <= maximumAmount else { return nil }
        return value
    }

    private static func isDigits(_ text: Substring) -> Bool {
        text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// The amount as the send flow's amount field holds it: "0.5", "12".
    private static func plain(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: posix)
    }
}
