import Foundation

/// A payment link ("envelope"): the seed of a one-time wallet that holds the
/// money, plus hints for the claim. Both apps build and parse the same bytes:
///
///     https://monero.one/c#v=1&s=<words>&h=<height>&a=<atomic>&e=<expiry>&n=<id>
///
/// The secret lives only in the URL fragment, so it never reaches a server.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Link format".
struct EnvelopeLink: Equatable {
    static let version = 1
    static let wordCount = 25
    /// Days a new link stays claimable. Advisory: nothing on chain enforces it.
    static let defaultLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// Confirmations before the envelope's money unlocks (wallet2's rule).
    static let confirmationsToUnlock = 10
    /// Blocks subtracted from the sender's daemon height for `h`.
    static let restoreHeightMargin: UInt64 = 10

    /// The 25-word legacy (English) mnemonic, lowercase.
    let words: [String]
    /// `h`: restore height for the envelope scan.
    let restoreHeight: UInt64
    /// `a`: the amount the sender meant, in piconero. A display hint only.
    let amount: UInt64
    /// `e`: expiry, unix seconds.
    let expiry: Int64
    /// `n`: envelope id, 16 lowercase hex characters.
    let id: String

    enum ParseError: Error, Equatable {
        /// Not a claim link at all (another URL, an address, free text).
        case notClaimLink
        /// `v` is present but not 1.
        case unsupportedVersion
        /// A key is missing or holds a bad value.
        case incomplete

        var message: String {
            switch self {
            case .notClaimLink:
                return String(localized: "This is not a Monero One payment link.")
            case .unsupportedVersion:
                return String(localized: "Update Monero One to open this link.")
            case .incomplete:
                return String(localized: "This link is not complete.")
            }
        }
    }

    // MARK: - Build

    /// The link string. Keys in the order v, s, h, a, e, n.
    var url: String {
        "https://monero.one/c#v=\(Self.version)&s=\(words.joined(separator: "-"))&h=\(restoreHeight)&a=\(amount)&e=\(expiry)&n=\(id)"
    }

    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiry)) }

    // MARK: - Parse

    /// True when `text` is shaped like a claim link (`monero.one/c#`), good
    /// or bad. A pasted or scanned claim link opens the claim sheet; it must
    /// never be read as an address.
    static func looksLikeClaimLink(_ text: String) -> Bool {
        fragment(of: text) != nil
    }

    /// Parses a claim link. Accepts `https://monero.one/c#...` and
    /// `monero.one/c#...` (pasted without a scheme). Rejects `http`.
    /// Unknown keys are ignored.
    static func parse(_ text: String) throws -> EnvelopeLink {
        guard let fragment = fragment(of: text) else { throw ParseError.notClaimLink }

        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            // First value wins, so a key appended later cannot override it.
            if fields[key] == nil { fields[key] = String(parts[1]) }
        }

        // Version first: a newer link must say "update", not "incomplete".
        guard let v = fields["v"] else { throw ParseError.incomplete }
        guard v == "\(version)" else { throw ParseError.unsupportedVersion }

        guard let s = fields["s"],
              let words = Self.words(fromField: s),
              let h = fields["h"].flatMap(Self.decimalUInt64),
              let a = fields["a"].flatMap(Self.decimalUInt64),
              let eRaw = fields["e"].flatMap(Self.decimalUInt64), eRaw <= UInt64(Int64.max),
              let n = fields["n"].map({ $0.lowercased() }), Self.isEnvelopeId(n)
        else {
            throw ParseError.incomplete
        }
        return EnvelopeLink(words: words, restoreHeight: h, amount: a, expiry: Int64(eRaw), id: n)
    }

    /// 16 lowercase hex characters.
    static func isEnvelopeId(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A new random envelope id (8 random bytes).
    static func newId() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Redaction

    /// Replaces the secret part of every claim link in `text`, for the
    /// diagnostic log: `monero.one/c#<redacted>`.
    static func redacted(in text: String) -> String {
        guard text.range(of: "monero.one/c", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(pattern: "(monero\\.one/c/?)(?:#|%23)[^\\s\"'<>]*", options: .caseInsensitive)
        else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1#<redacted>"
        )
    }

    // MARK: - Private

    /// The fragment after `monero.one/c#`, or nil when `text` is not a
    /// claim link.
    private static func fragment(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hashIndex = trimmed.firstIndex(of: "#") else { return nil }
        var head = trimmed[..<hashIndex].lowercased()
        if head.hasPrefix("https://") {
            head.removeFirst("https://".count)
        } else if head.contains("://") {
            // http and every other scheme.
            return nil
        }
        guard head == "monero.one/c" || head == "monero.one/c/" else { return nil }
        return String(trimmed[trimmed.index(after: hashIndex)...])
    }

    /// Lenient word split: `-`, `+`, `%20` or space. Exactly 25 words of
    /// letters, lowercased.
    private static func words(fromField field: String) -> [String]? {
        let decoded = field.replacingOccurrences(of: "%20", with: " ")
        let words = decoded
            .split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " })
            .map { $0.lowercased() }
        guard words.count == wordCount,
              words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter } }) else { return nil }
        return words
    }

    /// Plain decimal digits only (no sign, no spaces), within UInt64.
    private static func decimalUInt64(_ s: String) -> UInt64? {
        guard !s.isEmpty, s.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return UInt64(s)
    }
}
