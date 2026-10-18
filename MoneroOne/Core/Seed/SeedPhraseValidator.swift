import Foundation
import HdWalletKit

/// The three seed formats the restore flow accepts, by word count.
enum SeedFormat: Int, CaseIterable, Identifiable, Sendable {
    case polyseed = 16
    case bip39 = 24
    case legacy = 25

    var id: Int { rawValue }
    var wordCount: Int { rawValue }

    init?(wordCount: Int) {
        self.init(rawValue: wordCount)
    }
}

/// Validates seed words the way the restore path will read them: wallet2's
/// legacy rules for 25 words, the Polyseed C decoder for 16 words and the
/// HdWalletKit BIP39 check for 24 words. Pure and synchronous; the entry
/// screen calls it on every edit and `WalletManager` calls it again before it
/// saves a restored wallet.
enum SeedPhraseValidator {

    /// How one typed word relates to the format's word lists.
    struct WordMatch: Equatable {
        /// Indices (into the format's language list) of the lists that hold
        /// the word under that format's matching rules.
        let languages: [Int]
        /// The list word the text stands for, when every match is the same
        /// word. Display form (NFC).
        let canonical: String?

        var isKnown: Bool { !languages.isEmpty }
    }

    struct ValidPhrase: Equatable {
        /// The list words to pass to the restore, exactly as the native
        /// library stores them.
        let words: [String]
        let language: Int
        /// Polyseed only: the decoded wallet birthday.
        let birthday: Date?
    }

    enum Outcome: Equatable {
        /// Fewer non-empty words than the format needs.
        case incomplete
        case valid(ValidPhrase)
        /// Positions (0-based) of the words that are not in the best-matching
        /// list.
        case unknownWords([Int])
        /// Every word is known but the phrase fails the checksum (or another
        /// check the native library runs).
        case invalid
        /// A Polyseed with the encrypted (passphrase) feature bit.
        case passphrase
    }

    // MARK: - Normalization

    /// Typographic apostrophes as ASCII "'", then NFKC, locale-independent
    /// lowercase, no surrounding whitespace.
    static func normalize(_ token: String) -> String {
        asciiApostrophes(token)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ‘ ’ ‛ ʼ as ASCII "'", as Android does. 28 Lojban words hold an
    /// apostrophe (selma'o), and a document often stores it curly. No word
    /// list holds any of the four.
    static func asciiApostrophes(_ text: String) -> String {
        guard text.contains(where: typographicApostrophes.contains) else { return text }
        return String(text.map { typographicApostrophes.contains($0) ? "'" : $0 })
    }

    private static let typographicApostrophes: Set<Character> = ["\u{2018}", "\u{2019}", "\u{201B}", "\u{02BC}"]

    /// The form a list word takes in a cell: NFC (Polyseed and BIP39 lists
    /// are stored decomposed).
    static func displayForm(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
    }

    // MARK: - Languages

    static func languageCount(_ format: SeedFormat) -> Int {
        switch format {
        case .legacy: return SeedWordlists.legacy.count
        case .polyseed: return SeedWordlists.polyseed.count
        case .bip39: return Bip39Lists.lists.count
        }
    }

    static func englishIndex(_ format: SeedFormat) -> Int {
        switch format {
        case .legacy: return SeedWordlists.legacyEnglishIndex
        case .polyseed: return SeedWordlists.polyseedEnglishIndex
        case .bip39: return Bip39Lists.englishIndex
        }
    }

    // MARK: - One word

    /// The list index `token` resolves to in one language, under the format's
    /// rules. `token` must be normalized.
    static func resolve(_ token: String, format: SeedFormat, language: Int) -> Int? {
        guard !token.isEmpty else { return nil }
        switch format {
        case .legacy:
            return LegacySeedCodec.index(of: Array(token.utf8), in: SeedWordlists.legacy[language])
        case .polyseed:
            guard let key = PolyseedCodec.decompose(token) else { return nil }
            return PolyseedCodec.search(key, in: SeedWordlists.polyseed[language])
        case .bip39:
            return Bip39Lists.lists[language].resolve(token)
        }
    }

    /// The native list word at `index`.
    static func listWord(_ format: SeedFormat, language: Int, index: Int) -> String {
        switch format {
        case .legacy: return SeedWordlists.legacy[language].words[index]
        case .polyseed: return SeedWordlists.polyseed[language].words[index]
        case .bip39: return Bip39Lists.lists[language].words[index]
        }
    }

    static func match(_ token: String, format: SeedFormat) -> WordMatch {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return WordMatch(languages: [], canonical: nil) }
        var languages: [Int] = []
        var words: [String] = []
        for language in 0..<languageCount(format) {
            guard let index = resolve(normalized, format: format, language: language) else { continue }
            languages.append(language)
            let word = displayForm(listWord(format, language: language, index: index))
            if !words.contains(word) {
                words.append(word)
            }
        }
        return WordMatch(languages: languages, canonical: words.count == 1 ? words[0] : nil)
    }

    /// What a cell shows after commit: the list word when the text stands for
    /// exactly one. When the matches disagree, the active language (the one
    /// most committed words match) decides, but only when it leads outright
    /// ("bee" in an English phrase is "beer", although English (old) has
    /// "bee"). Otherwise the text stays as typed, which also keeps a full
    /// list word of another language as it is.
    static func canonicalOnCommit(_ token: String, format: SeedFormat, committed: [String]) -> String {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return "" }
        let match = match(normalized, format: format)
        if let canonical = match.canonical {
            return canonical
        }
        guard match.isKnown else { return normalized }
        let counts = matchCounts(committed, format: format)
        if let best = counts.enumerated().max(by: { $0.element < $1.element }),
           best.element > 0,
           counts.enumerated().allSatisfy({ $0.offset == best.offset || $0.element < best.element }),
           match.languages.contains(best.offset),
           let index = resolve(normalized, format: format, language: best.offset) {
            return displayForm(listWord(format, language: best.offset, index: index))
        }
        return normalized
    }

    /// Per language: how many of `tokens` it holds.
    static func matchCounts(_ tokens: [String], format: SeedFormat) -> [Int] {
        var counts = [Int](repeating: 0, count: languageCount(format))
        for token in tokens {
            let normalized = normalize(token)
            guard !normalized.isEmpty else { continue }
            for language in counts.indices where resolve(normalized, format: format, language: language) != nil {
                counts[language] += 1
            }
        }
        return counts
    }

    /// The language that holds the most of `tokens`; ties go to English, then
    /// to list order.
    static func activeLanguage(_ tokens: [String], format: SeedFormat) -> Int {
        let counts = matchCounts(tokens, format: format)
        let english = englishIndex(format)
        guard let top = counts.max() else { return english }
        if counts[english] == top { return english }
        return counts.firstIndex(of: top) ?? english
    }

    /// Up to `limit` list words for a cell: the word the text resolves to,
    /// then the list words that start with the text (accents ignored).
    /// Words come from the active language; when no committed word decides
    /// it, the first language (English first) with any suggestion is used.
    static func suggestions(for token: String, format: SeedFormat, committed: [String], limit: Int = 3) -> [String] {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return [] }
        let counts = matchCounts(committed, format: format)
        let english = englishIndex(format)
        let top = counts.max() ?? 0
        var order = counts.indices.filter { counts[$0] == top }
        if let e = order.firstIndex(of: english) {
            order.remove(at: e)
            order.insert(english, at: 0)
        }
        for language in order {
            let words = suggestions(normalized, format: format, language: language, limit: limit)
            if !words.isEmpty {
                return words
            }
        }
        return []
    }

    static func suggestions(_ normalized: String, format: SeedFormat, language: Int, limit: Int) -> [String] {
        var result: [String] = []
        if let index = resolve(normalized, format: format, language: language) {
            result.append(displayForm(listWord(format, language: language, index: index)))
        }
        let folded = SuggestionIndex.fold(normalized)
        let index = SuggestionIndex.index(format, language: language)
        for (i, word) in index.folded.enumerated() where result.count < limit {
            if word.hasPrefix(folded), !result.contains(index.display[i]) {
                result.append(index.display[i])
            }
        }
        return result
    }

    // MARK: - Whole phrase

    static func validate(_ tokens: [String], format: SeedFormat) -> Outcome {
        let normalized = tokens.map(normalize)
        guard normalized.count == format.wordCount, !normalized.contains(where: \.isEmpty) else {
            return .incomplete
        }
        // A word with a space inside never survives the native split.
        if let bad = normalized.firstIndex(where: { $0.contains(where: \.isWhitespace) }) {
            return .unknownWords([bad])
        }
        switch format {
        case .legacy: return validateLegacy(normalized)
        case .polyseed: return validatePolyseed(normalized)
        case .bip39: return validateBip39(normalized)
        }
    }

    /// Positions not held by the best-matching list (most matches, ties to
    /// English, then list order).
    static func unknownPositions(_ tokens: [String], format: SeedFormat) -> [Int] {
        let best = activeLanguage(tokens, format: format)
        return tokens.indices.filter { resolve(tokens[$0], format: format, language: best) == nil }
    }

    private static func validateLegacy(_ tokens: [String]) -> Outcome {
        switch LegacySeedCodec.decode(tokens) {
        case .valid(let language, let words):
            // The restore receives the list words; they must decode the same.
            guard case .valid(language, words) = LegacySeedCodec.decode(words.map(normalize)) else {
                return .invalid
            }
            return .valid(ValidPhrase(words: words, language: language, birthday: nil))
        case .checksumFailed, .invalidTriple, .wrongCount:
            return .invalid
        case .unknownWords:
            return .unknownWords(unknownPositions(tokens, format: .legacy))
        }
    }

    private static func validatePolyseed(_ tokens: [String]) -> Outcome {
        switch PolyseedCodec.decode(tokens.joined(separator: " ")) {
        case .ok(let language, let indices, let data):
            let list = SeedWordlists.polyseed[language]
            let words = indices.map { list.words[$0] }
            // The restore receives the list words joined by a space; they
            // must decode to the same seed (this also applies wallet2's
            // normalization size limit to what it will actually read).
            guard case .ok(language, indices, data) = PolyseedCodec.decode(words.joined(separator: " ")) else {
                return .invalid
            }
            if data.isEncrypted {
                return .passphrase
            }
            return .valid(ValidPhrase(words: words, language: language, birthday: data.birthdayDate))
        case .errLang:
            return .unknownWords(unknownPositions(tokens, format: .polyseed))
        case .errNumWords, .errChecksum, .errUnsupported, .errMultLang, .errNormalization:
            return .invalid
        }
    }

    private static func validateBip39(_ tokens: [String]) -> Outcome {
        var anyResolved = false
        for list in Bip39Lists.lists {
            var words: [String] = []
            for token in tokens {
                guard let index = list.resolve(token) else { break }
                words.append(list.words[index])
            }
            guard words.count == tokens.count else { continue }
            anyResolved = true
            if Mnemonic.isValid(words: words), let language = Bip39Lists.lists.firstIndex(where: { $0.language == list.language }) {
                return .valid(ValidPhrase(words: words, language: language, birthday: nil))
            }
        }
        if anyResolved {
            return .invalid
        }
        return .unknownWords(unknownPositions(tokens, format: .bip39))
    }
}

// MARK: - BIP39 lists

/// HdWalletKit's BIP39 lists, in `Mnemonic.Language.allCases` order (the
/// order `Mnemonic.validate` tries them).
struct Bip39Wordlist {
    let language: Mnemonic.Language
    /// The list words as HdWalletKit stores them.
    let words: [String]
    /// Word -> index. Swift `String` hashing and equality are
    /// normalization-insensitive, so NFC text finds NFD list words.
    private let indexByWord: [String: Int]
    /// First four characters -> indices, for prefix expansion.
    private let indicesByPrefix: [String: [Int]]

    init(language: Mnemonic.Language) {
        self.language = language
        let words = Mnemonic.wordList(for: language).map(String.init)
        self.words = words
        var byWord: [String: Int] = [:]
        var byPrefix: [String: [Int]] = [:]
        for (i, word) in words.enumerated() {
            let display = word.precomposedStringWithCanonicalMapping
            if byWord[display] == nil {
                byWord[display] = i
            }
            if display.count >= 4 {
                byPrefix[String(display.prefix(4)), default: []].append(i)
            }
        }
        indexByWord = byWord
        indicesByPrefix = byPrefix
    }

    /// An exact list word, or a unique prefix of four or more letters.
    func resolve(_ token: String) -> Int? {
        if let index = indexByWord[token] {
            return index
        }
        guard token.count >= 4, let candidates = indicesByPrefix[String(token.prefix(4))] else { return nil }
        let matches = candidates.filter { words[$0].precomposedStringWithCanonicalMapping.hasPrefix(token) }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum Bip39Lists {
    static let lists: [Bip39Wordlist] = Mnemonic.Language.allCases.map(Bip39Wordlist.init)
    static var englishIndex: Int { lists.firstIndex { $0.language == .english } ?? 0 }
}

// MARK: - Suggestions

/// Accent-folded copies of every list, built on first use per list.
enum SuggestionIndex {
    struct Entry {
        let display: [String]
        let folded: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func index(_ format: SeedFormat, language: Int) -> Entry {
        let key = "\(format.rawValue)-\(language)"
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[key] {
            return entry
        }
        let words: [String]
        switch format {
        case .legacy: words = SeedWordlists.legacy[language].words
        case .polyseed: words = SeedWordlists.polyseed[language].words
        case .bip39: words = Bip39Lists.lists[language].words
        }
        let display = words.map(SeedPhraseValidator.displayForm)
        let entry = Entry(display: display, folded: display.map(fold))
        cache[key] = entry
        return entry
    }
}
