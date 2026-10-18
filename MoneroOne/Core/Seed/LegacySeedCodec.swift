import Foundation

/// Swift port of wallet2's legacy (Electrum-style, 25-word) seed checks:
/// `src/mnemonics/electrum-words.cpp` (`find_seed_language`, `checksum_test`,
/// `create_checksum_index`, `words_to_bytes`) and `language_base.h`
/// (`utf8prefix`, the trimmed word map). Matching is byte-exact on UTF-8
/// like the C++; both sides are lower-cased, as `WordEqual` does.
enum LegacySeedCodec {
    static let wordCount = 25

    enum Result: Equatable {
        /// Every word is in `language`, the checksum and every word triple
        /// pass. `words` are the list words wallet2 resolves the input to.
        case valid(language: Int, words: [String])
        /// Every word is in a list, but the checksum word does not match
        /// (wallet2's fallback language).
        case checksumFailed(language: Int)
        /// The checksum passes but a word triple overflows uint32 in
        /// `words_to_bytes` ("Invalid seed: mumble mumble").
        case invalidTriple(language: Int)
        /// No list holds every word.
        case unknownWords
        /// Not 25 words.
        case wrongCount
    }

    /// `Language::utf8prefix`: at most `count` code points, counted by UTF-8
    /// lead bytes. Assumes well-formed UTF-8, like the C++.
    static func utf8Prefix(_ s: [UInt8], _ count: Int) -> [UInt8] {
        var prefix: [UInt8] = []
        prefix.reserveCapacity(min(s.count, count * 4))
        var remaining = count
        var avail = s.count
        var i = 0
        while remaining > 0 && avail > 0 {
            remaining -= 1
            avail -= 1
            prefix.append(s[i])
            i += 1
            while avail > 0 && (s[i] & 0xC0) == 0x80 {
                prefix.append(s[i])
                i += 1
                avail -= 1
            }
        }
        return prefix
    }

    /// Index of a typed word in `list` under wallet2's trimmed-map lookup:
    /// `utf8prefix(word, unique_prefix_length)` must equal a list word's key.
    /// `token` must already be lower-cased and NFC.
    static func index(of token: [UInt8], in list: LegacyWordlist) -> Int? {
        list.indexByLowerKey[utf8Prefix(token, list.prefixLength)]
    }

    /// Full wallet2 decode of 25 lower-cased NFC words (`words_to_bytes` with
    /// a 32-byte key, which calls `find_seed_language` and `checksum_test`).
    static func decode(_ tokens: [String], lists: [LegacyWordlist] = SeedWordlists.legacy) -> Result {
        guard tokens.count == wordCount else { return .wrongCount }
        let seed = tokens.map { Array($0.utf8) }

        // find_seed_language (has_checksum == true for 25 words)
        var fallback: Int?
        var found: (language: Int, indices: [Int])?
        for (li, list) in lists.enumerated() {
            var indices: [Int] = []
            indices.reserveCapacity(seed.count)
            var fullMatch = true
            for word in seed {
                guard let index = index(of: word, in: list) else {
                    fullMatch = false
                    break
                }
                indices.append(index)
            }
            if fullMatch && !checksumTest(seed, list) {
                fallback = li
                fullMatch = false
            }
            if fullMatch {
                found = (li, indices)
                break
            }
        }

        guard let found else {
            if let fallback {
                // find_seed_language returns the fallback; words_to_bytes then
                // fails its own checksum_test.
                return .checksumFailed(language: fallback)
            }
            return .unknownWords
        }

        // words_to_bytes: the checksum passed inside find_seed_language; drop
        // the checksum word and run the 3-word -> 4-byte check per triple.
        let wordListLength = UInt32(lists[found.language].words.count)
        let indices = found.indices.dropLast().map { UInt32($0) }
        for i in 0..<(indices.count / 3) {
            let w1 = indices[i * 3]
            let w2 = indices[i * 3 + 1]
            let w3 = indices[i * 3 + 2]
            if !tripleIsValid(w1, w2, w3, wordListLength: wordListLength) {
                return .invalidTriple(language: found.language)
            }
        }

        let list = lists[found.language]
        return .valid(language: found.language, words: found.indices.map { list.words[$0] })
    }

    /// The `words_to_bytes` triple check, in uint32 arithmetic with
    /// wraparound exactly as the C++ computes it:
    /// `w0 = w1 + n*(((n - w1) + w2) % n) + n*n*(((n - w2) + w3) % n)`, then
    /// `w0 % n == w1`. The last term overflows when `w3 == w2 - 1 (mod n)`.
    static func tripleIsValid(_ w1: UInt32, _ w2: UInt32, _ w3: UInt32, wordListLength n: UInt32) -> Bool {
        let w0 = w1 &+ n &* (((n &- w1) &+ w2) % n) &+ n &* n &* (((n &- w2) &+ w3) % n)
        return w0 % n == w1
    }

    /// `checksum_test`: the last word must equal, by prefix, the word at
    /// `create_checksum_index` of the first 24.
    static func checksumTest(_ seed: [[UInt8]], _ list: LegacyWordlist) -> Bool {
        guard let lastWord = seed.last else { return false }
        let body = Array(seed.dropLast())
        guard let idx = checksumIndex(body, list) else { return false }
        let n = list.prefixLength
        let trimmedChecksum = SeedWordlists.lowerBytes(utf8Prefix(body[idx], n))
        let trimmedLast = SeedWordlists.lowerBytes(utf8Prefix(lastWord, n))
        return trimmedChecksum == trimmedLast
    }

    /// `create_checksum_index`: CRC32 over the concatenated trimmed-map keys
    /// (the list's own prefixes, original case), mod the word count. Nil
    /// where the C++ throws (a word missing from the trimmed map).
    static func checksumIndex(_ words: [[UInt8]], _ list: LegacyWordlist) -> Int? {
        guard !words.isEmpty else { return nil }
        var trimmed: [UInt8] = []
        for word in words {
            guard let index = index(of: word, in: list) else { return nil }
            trimmed.append(contentsOf: list.keys[index])
        }
        return Int(crc32(trimmed) % UInt32(words.count))
    }

    /// Port of `bytes_to_words` for a 32-byte key (tests and golden vectors):
    /// 4 bytes -> 3 words, plus the checksum word.
    static func encode(_ key: [UInt8], list: LegacyWordlist) -> [String]? {
        guard key.count % 4 == 0, !key.isEmpty else { return nil }
        let n = UInt32(list.words.count)
        var indices: [Int] = []
        for i in 0..<(key.count / 4) {
            let w0 = UInt32(key[i * 4]) | UInt32(key[i * 4 + 1]) << 8 | UInt32(key[i * 4 + 2]) << 16 | UInt32(key[i * 4 + 3]) << 24
            let w1 = w0 % n
            let w2 = ((w0 / n) + w1) % n
            let w3 = (((w0 / n) / n) + w2) % n
            indices.append(contentsOf: [Int(w1), Int(w2), Int(w3)])
        }
        let words = indices.map { list.words[$0] }
        guard let checksum = checksumIndex(words.map { Array($0.lowercased().utf8) }, list) else { return nil }
        return words + [words[checksum]]
    }

    // MARK: - CRC32 (boost::crc_32_type: reflected 0xEDB88320, init and xorout 0xFFFFFFFF)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
