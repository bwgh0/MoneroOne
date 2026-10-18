import Foundation

/// Splits pasted text into seed words: typographic apostrophes as "'"
/// (Lojban), NFKC, lowercase, split on any whitespace (U+3000 included),
/// commas and semicolons; drops numbering (`12`, `12.`, `12)`, `12:`, `#12`,
/// and `12.word` glued to a word), and strips surrounding quotes, brackets,
/// bullets and trailing periods.
enum SeedPasteParser {
    private static let separators: Set<Character> = [",", ";", "、", "，", "；"]
    private static let wrappers: Set<Character> = [
        "\"", "'", "`", "“", "”", "„", "‘", "’", "‚", "«", "»", "‹", "›",
        "「", "」", "『", "』", "(", ")", "[", "]", "{", "}", "<", ">", "（", "）", "【", "】"
    ]
    private static let trailingStops: Set<Character> = [".", "。", "…", "!", "?"]
    private static let bullets: Set<Character> = ["-", "–", "—", "•", "·", "*", "・"]

    static func parse(_ text: String) -> [String] {
        let normalized = SeedPhraseValidator.asciiApostrophes(text).precomposedStringWithCompatibilityMapping.lowercased()
        let rawTokens = normalized.split(whereSeparator: { $0.isWhitespace || separators.contains($0) })
        return rawTokens.compactMap { clean(String($0)) }
    }

    /// One raw token -> a seed word, or nil when the token is numbering or
    /// holds no letters.
    static func clean(_ raw: String) -> String? {
        var token = strip(raw)
        if isNumbering(token) {
            return nil
        }
        token = stripGluedNumbering(token)
        token = strip(token)
        guard token.contains(where: \.isLetter) else {
            return nil
        }
        return token.precomposedStringWithCompatibilityMapping
    }

    /// Removes wrapping quotes and brackets, leading bullets and trailing
    /// periods, repeatedly, from both ends.
    private static func strip(_ token: String) -> String {
        var chars = Substring(token)
        var changed = true
        while changed, !chars.isEmpty {
            changed = false
            if let first = chars.first, wrappers.contains(first) || bullets.contains(first) {
                chars = chars.dropFirst()
                changed = true
            }
            if let last = chars.last, wrappers.contains(last) || trailingStops.contains(last) {
                chars = chars.dropLast()
                changed = true
            }
        }
        return String(chars)
    }

    /// `12`, `12.`, `12)`, `12:`, `#12` (after `strip`, which already took
    /// off a trailing period or bracket).
    private static func isNumbering(_ token: String) -> Bool {
        var chars = Substring(token)
        if chars.first == "#" {
            chars = chars.dropFirst()
        }
        if let last = chars.last, last == ":" || last == "." || last == ")" {
            chars = chars.dropLast()
        }
        return !chars.isEmpty && chars.allSatisfy(\.isASCIIDigit)
    }

    /// `12.word`, `12)word`, `12:word`, `#12.word`, `12word` -> `word`.
    private static func stripGluedNumbering(_ token: String) -> String {
        var chars = Substring(token)
        if chars.first == "#" {
            chars = chars.dropFirst()
        }
        let digits = chars.prefix(while: \.isASCIIDigit)
        guard !digits.isEmpty else { return token }
        var rest = chars.dropFirst(digits.count)
        if let first = rest.first, first == "." || first == ")" || first == ":" || first == "-" {
            rest = rest.dropFirst()
        }
        return rest.contains(where: \.isLetter) ? String(rest) : token
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
