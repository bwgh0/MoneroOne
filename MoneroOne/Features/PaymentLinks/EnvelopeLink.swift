import Foundation

/// A payment link ("envelope"): the secret of a one-time wallet that holds
/// the money, plus hints for the claim. Both apps build and parse the same
/// bytes. New links are v2 (`EnvelopeV2`, about 48 characters):
///
///     https://monero.one/c#2<secret><height>
///
/// v1 links still parse and claim (links funded before v2 must keep working):
///
///     https://monero.one/c#v=1&s=<words>&h=<height>&a=<atomic>&e=<expiry>&n=<id>
///
/// The secret lives only in the URL fragment, so it never reaches a server.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Link format" and "Link
/// format v2".
struct EnvelopeLink: Equatable {
    enum Format: Equatable {
        /// The 25 words are in the link.
        case v1
        /// A 16-byte secret is in the link; the words derive from it.
        case v2(secret: [UInt8])
    }

    /// The key-value format's version (`v=1`).
    static let version = 1
    static let wordCount = 25
    /// Days a new link stays claimable. Advisory: nothing on chain enforces it.
    static let defaultLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// Confirmations before the envelope's money unlocks (wallet2's rule).
    static let confirmationsToUnlock = 10
    /// Blocks subtracted from the sender's daemon height for `h`.
    static let restoreHeightMargin: UInt64 = 10

    let format: Format
    /// The 25-word legacy (English) mnemonic the envelope wallet restores
    /// from, lowercase. v1: from the link; v2: derived from the secret.
    let words: [String]
    /// `h`: restore height for the envelope scan.
    let restoreHeight: UInt64
    /// `a`: the amount the sender meant, in piconero. A display hint only.
    /// 0 in v2, which carries no amount.
    let amount: UInt64
    /// `e`: expiry, unix seconds. 0 in v2, which carries no expiry.
    let expiry: Int64
    /// Envelope id, 16 lowercase hex characters. v1: `n`; v2: derived.
    let id: String

    /// A v1 link.
    init(words: [String], restoreHeight: UInt64, amount: UInt64, expiry: Int64, id: String) {
        self.format = .v1
        self.words = words
        self.restoreHeight = restoreHeight
        self.amount = amount
        self.expiry = expiry
        self.id = id
    }

    /// A v2 link. Nil when `secret` is not 16 bytes (or, never in practice,
    /// derives a zero spend key).
    init?(secret: [UInt8], restoreHeight: UInt64) {
        guard secret.count == EnvelopeV2.secretByteCount,
              let words = EnvelopeV2.words(secret: secret) else { return nil }
        self.format = .v2(secret: secret)
        self.words = words
        self.restoreHeight = restoreHeight
        self.amount = 0
        self.expiry = 0
        self.id = EnvelopeV2.id(secret: secret)
    }

    /// The v2 secret, nil for a v1 link.
    var secret: [UInt8]? {
        if case .v2(let secret) = format { return secret }
        return nil
    }

    enum ParseError: Error, Equatable {
        /// Not a claim link at all (another URL, an address, free text).
        case notClaimLink
        /// A version this app does not know (`v` other than 1, or a short
        /// link whose first character is not `2`).
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

    /// The link string. v1 keys in the order v, s, h, a, e, n.
    var url: String {
        switch format {
        case .v1:
            return "https://monero.one/c#v=\(Self.version)&s=\(words.joined(separator: "-"))&h=\(restoreHeight)&a=\(amount)&e=\(expiry)&n=\(id)"
        case .v2(let secret):
            return "https://monero.one/c#" + (EnvelopeV2.fragment(secret: secret, restoreHeight: restoreHeight) ?? "")
        }
    }

    /// Nil when the link carries no expiry (v2).
    var expiryDate: Date? { expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : nil }

    // MARK: - Parse

    /// True when `text` is shaped like a claim link (`monero.one/c#`), good
    /// or bad. A pasted or scanned claim link opens the claim sheet; it must
    /// never be read as an address.
    static func looksLikeClaimLink(_ text: String) -> Bool {
        fragment(of: text) != nil
    }

    /// Parses a claim link. Accepts `https://monero.one/c#...` and
    /// `monero.one/c#...` (pasted without a scheme). Rejects `http`.
    /// A fragment with `=` is the v1 key-value format (unknown keys are
    /// ignored); one without is the short format, whose first character is
    /// the version.
    static func parse(_ text: String) throws -> EnvelopeLink {
        guard let fragment = fragment(of: text) else { throw ParseError.notClaimLink }
        guard fragment.contains("=") else { return try parseShort(fragment) }

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

    /// The short format: `2<secret><height>`.
    private static func parseShort(_ fragment: String) throws -> EnvelopeLink {
        guard let first = fragment.first else { throw ParseError.incomplete }
        guard first == EnvelopeV2.versionCharacter else {
            // Another version character: a newer link. Anything else
            // (a cut or mangled link) is incomplete.
            throw first.isASCII && (first.isLetter || first.isNumber) ? ParseError.unsupportedVersion : ParseError.incomplete
        }
        guard let body = EnvelopeV2.parseBody(fragment.dropFirst()),
              let link = EnvelopeLink(secret: body.secret, restoreHeight: body.restoreHeight)
        else {
            throw ParseError.incomplete
        }
        return link
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
