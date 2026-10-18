import Foundation

/// One wallet2 legacy (25-word) list, as `src/mnemonics/*.h` stores it.
struct LegacyWordlist: Sendable {
    let englishName: String
    /// wallet2 `unique_prefix_length` (English 3, Japanese 3, Chinese 1, others 4).
    let prefixLength: Int
    /// The words exactly as wallet2 stores them: precomposed UTF-8, German
    /// nouns capitalized. Canonical words passed to the restore are these.
    let words: [String]
    /// wallet2 `trimmed_word_map` key per index, original case. The checksum
    /// CRC32 runs over these keys.
    let keys: [[UInt8]]
    /// Lower-cased key -> index. wallet2's `WordEqual`/`WordHash` lower both
    /// sides; on a duplicate prefix (English (old)) the last index wins, as in
    /// `populate_maps`.
    let indexByLowerKey: [[UInt8]: Int]
    /// Lower-cased words, for suggestions.
    let lowerWords: [String]
}

/// One Polyseed list, as `external/polyseed/src/lang_*.c` stores it.
struct PolyseedWordlist: Sendable {
    let englishName: String
    let separator: String
    let isSorted: Bool
    let hasPrefix: Bool
    let hasAccents: Bool
    let compose: Bool
    /// The words exactly as polyseed stores them (NFKD UTF-8).
    let words: [String]
    /// C strings of `words` (signed bytes plus a 0 terminator), for the
    /// byte-exact comparers of `lang.c`.
    let cWords: [[Int8]]
    /// C string -> first index. For the unsorted lists (no prefix, no
    /// accents) `lang_search`'s linear `compare_str` scan is an exact-match
    /// lookup, so this gives the same answer without 2048 compares.
    let exactIndex: [[Int8]: Int]
}

/// The seed word lists bundled from the monero sources. The files in
/// `Resources/SeedWordlists` are byte-identical to the ones the Android app
/// ships. Lists load once, on first use.
enum SeedWordlists {
    /// wallet2 `find_seed_language` order.
    static let legacyOrder = [
        "Chinese (simplified)", "English", "Dutch", "French", "Spanish", "German",
        "Italian", "Portuguese", "Japanese", "Russian", "Esperanto", "Lojban", "English (old)"
    ]
    /// polyseed `lang.c` `languages[]` order.
    static let polyseedOrder = [
        "English", "Japanese", "Korean", "Spanish", "French", "Italian", "Czech",
        "Portuguese", "Chinese (Simplified)", "Chinese (Traditional)"
    ]

    static let legacy: [LegacyWordlist] = loadLegacy()
    static let polyseed: [PolyseedWordlist] = loadPolyseed()

    static var legacyEnglishIndex: Int { legacyOrder.firstIndex(of: "English") ?? 0 }
    static var polyseedEnglishIndex: Int { polyseedOrder.firstIndex(of: "English") ?? 0 }

    // MARK: - Loading

    private struct Manifest: Decodable {
        struct Legacy: Decodable {
            let file: String
            let englishName: String
            let uniquePrefixLength: Int
            let count: Int
        }
        struct Poly: Decodable {
            let file: String
            let englishName: String
            let separator: String
            let isSorted: Bool
            let hasPrefix: Bool
            let hasAccents: Bool
            let compose: Bool
            let count: Int
        }
        let legacy: [Legacy]
        let polyseed: [Poly]
    }

    private static let directory = "SeedWordlists"

    private static let manifest: Manifest? = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: directory),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            assertionFailure("SeedWordlists/manifest.json missing from the app bundle")
            return nil
        }
        return manifest
    }()

    private static func readWords(_ file: String, expected: Int) -> [String]? {
        // Manifest paths look like "legacy/english.txt".
        let parts = file.split(separator: "/").map(String.init)
        let subdirectory = ([directory] + parts.dropLast()).joined(separator: "/")
        guard let name = parts.last,
              let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdirectory),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Seed word list \(file) missing from the app bundle")
            return nil
        }
        let words = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard words.count == expected else {
            assertionFailure("Seed word list \(file) has \(words.count) words, expected \(expected)")
            return nil
        }
        return words
    }

    private static func loadLegacy() -> [LegacyWordlist] {
        guard let manifest else { return [] }
        return legacyOrder.compactMap { name in
            guard let entry = manifest.legacy.first(where: { $0.englishName == name }),
                  let words = readWords(entry.file, expected: entry.count) else { return nil }
            let n = entry.uniquePrefixLength
            var keys: [[UInt8]] = []
            keys.reserveCapacity(words.count)
            var index: [[UInt8]: Int] = [:]
            index.reserveCapacity(words.count)
            for (i, word) in words.enumerated() {
                let bytes = Array(word.utf8)
                // populate_maps: `it->length() > unique_prefix_length ? utf8prefix : word`
                let key = bytes.count > n ? LegacySeedCodec.utf8Prefix(bytes, n) : bytes
                keys.append(key)
                index[lowerBytes(key)] = i
            }
            return LegacyWordlist(
                englishName: name,
                prefixLength: n,
                words: words,
                keys: keys,
                indexByLowerKey: index,
                lowerWords: words.map { $0.lowercased() }
            )
        }
    }

    private static func loadPolyseed() -> [PolyseedWordlist] {
        guard let manifest else { return [] }
        return polyseedOrder.compactMap { name in
            guard let entry = manifest.polyseed.first(where: { $0.englishName == name }),
                  let words = readWords(entry.file, expected: entry.count) else { return nil }
            // The manifest writes the Japanese separator escaped ("\\u3000").
            let separator = entry.separator == "\\u3000" ? "\u{3000}" : entry.separator
            let cWords = words.map { PolyseedCodec.cString($0) }
            var exactIndex: [[Int8]: Int] = [:]
            for (i, word) in cWords.enumerated() where exactIndex[word] == nil {
                exactIndex[word] = i
            }
            return PolyseedWordlist(
                englishName: name,
                separator: separator,
                isSorted: entry.isSorted,
                hasPrefix: entry.hasPrefix,
                hasAccents: entry.hasAccents,
                compose: entry.compose,
                words: words,
                cWords: cWords,
                exactIndex: exactIndex
            )
        }
    }

    /// wallet2 compares words with `towlower` on both sides; lower the key
    /// the same way the typed text is lowered.
    static func lowerBytes(_ bytes: [UInt8]) -> [UInt8] {
        Array(String(decoding: bytes, as: UTF8.self).lowercased().utf8)
    }
}
