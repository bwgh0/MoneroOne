import Foundation

/// Swift port of the Polyseed decoder in `external/polyseed/src` (the copy
/// wallet2 builds): `polyseed.c` (`polyseed_decode`, `str_split`), `lang.c`
/// (the comparers, `lang_search`, `polyseed_phrase_decode`), `gf.h`/`gf.c`
/// (GF(2048) checksum, `polyseed_poly_to_data`), `features.c` and
/// `birthday.h`. Words compare as C strings of signed chars, like the C code
/// on Apple platforms.
enum PolyseedCodec {
    static let wordCount = 16
    /// `POLYSEED_STR_SIZE`
    static let strSize = 360
    /// `EPOCH` in birthday.h: 1 November 2021 12:00 UTC.
    static let epoch: UInt64 = 1_635_768_000
    /// `TIME_STEP` in birthday.h: 1/12 of the Gregorian year.
    static let timeStep: UInt64 = 2_629_746
    /// `POLYSEED_MONERO`
    static let coinMonero: UInt16 = 0

    private static let gfBits = 11
    /// `SECRET_BITS`
    private static let secretBitCount = 150
    private static let dateBits = 10
    private static let dateMask: UInt = (1 << 10) - 1
    private static let featureBits = 5
    private static let featureMask: UInt = (1 << 5) - 1
    /// `ENCRYPTED_MASK`
    static let encryptedMask: UInt = 16
    /// `reserved_features` with no user features enabled (wallet2 never
    /// calls `polyseed_enable_features`).
    private static let reservedFeatures: UInt = featureMask ^ encryptedMask
    private static let numCharsPrefix = 4
    private static let mul2Table: [UInt16] = [5, 7, 1, 3, 13, 15, 9, 11]

    /// `polyseed_data`
    struct SeedData: Equatable {
        var birthday: UInt
        var features: UInt
        var secret: [UInt8]
        var checksum: UInt16

        var isEncrypted: Bool { features & PolyseedCodec.encryptedMask != 0 }

        /// `polyseed_get_birthday`
        var birthdayTimestamp: UInt64 { PolyseedCodec.birthdayDecode(birthday) }
        var birthdayDate: Date { Date(timeIntervalSince1970: TimeInterval(birthdayTimestamp)) }
    }

    /// `polyseed_status`
    enum Status: Equatable {
        case ok(language: Int, indices: [Int], data: SeedData)
        case errNumWords
        case errLang
        case errChecksum
        case errUnsupported
        case errMultLang
        /// wallet2's utf8proc wrapper throws "Unicode normalization failed".
        case errNormalization
    }

    // MARK: - C strings

    /// UTF-8 bytes as C `char` (signed on Apple platforms) plus a terminator.
    static func cString(_ s: String) -> [Int8] {
        var bytes = s.utf8.map { Int8(bitPattern: $0) }
        bytes.append(0)
        return bytes
    }

    private static func sign(_ a: Int8, _ b: Int8) -> Int {
        (a > b ? 1 : 0) - (a < b ? 1 : 0)
    }

    // MARK: - lang.c comparers

    static func compareStr(_ key: [Int8], _ elm: [Int8]) -> Int {
        var k = 0
        var e = 0
        while true {
            if key[k] == 0 || key[k] != elm[e] { break }
            k += 1
            e += 1
        }
        return sign(key[k], elm[e])
    }

    static func comparePrefix(_ key: [Int8], _ elm: [Int8], _ n: Int) -> Int {
        var k = 0
        var e = 0
        var i = 1
        while true {
            if key[k] == 0 { break }
            if i >= n && key[k + 1] == 0 { break }
            if key[k] != elm[e] { break }
            k += 1
            e += 1
            i += 1
        }
        return sign(key[k], elm[e])
    }

    static func compareStrNoAccent(_ key: [Int8], _ elm: [Int8]) -> Int {
        var k = 0
        var e = 0
        while true {
            while key[k] < 0 { k += 1 }
            while elm[e] < 0 { e += 1 }
            if key[k] == 0 || key[k] != elm[e] { break }
            k += 1
            e += 1
        }
        return sign(key[k], elm[e])
    }

    static func comparePrefixNoAccent(_ key: [Int8], _ elm: [Int8], _ n: Int) -> Int {
        var k = 0
        var e = 0
        var i = 1
        while true {
            while key[k] < 0 { k += 1 }
            while elm[e] < 0 { e += 1 }
            if key[k] == 0 { break }
            if i >= n && key[k + 1] == 0 { break }
            if key[k] != elm[e] { break }
            k += 1
            e += 1
            i += 1
        }
        while key[k] < 0 { k += 1 }
        while elm[e] < 0 { e += 1 }
        return sign(key[k], elm[e])
    }

    /// `get_comparer`
    static func compare(_ key: [Int8], _ elm: [Int8], list: PolyseedWordlist) -> Int {
        if list.hasPrefix {
            return list.hasAccents
                ? comparePrefixNoAccent(key, elm, numCharsPrefix)
                : comparePrefix(key, elm, numCharsPrefix)
        }
        return list.hasAccents ? compareStrNoAccent(key, elm) : compareStr(key, elm)
    }

    /// `lang_search`: libc `bsearch` (the BSD algorithm Apple and Android
    /// ship) on sorted lists, a linear scan on the others.
    static func search(_ key: [Int8], in list: PolyseedWordlist) -> Int? {
        if list.isSorted {
            var base = 0
            var lim = list.cWords.count
            while lim != 0 {
                let p = base + (lim >> 1)
                let cmp = compare(key, list.cWords[p], list: list)
                if cmp == 0 { return p }
                if cmp > 0 {
                    base = p + 1
                    lim -= 1
                }
                lim >>= 1
            }
            return nil
        }
        if !list.hasPrefix && !list.hasAccents {
            // compare_str is exact equality; the first equal word wins.
            return list.exactIndex[key]
        }
        for (j, word) in list.cWords.enumerated() where compare(key, word, list: list) == 0 {
            return j
        }
        return nil
    }

    /// Linear reference search (tests check `search` against it).
    static func linearSearch(_ key: [Int8], in list: PolyseedWordlist) -> Int? {
        list.cWords.firstIndex { compare(key, $0, list: list) == 0 }
    }

    // MARK: - Normalization and splitting

    /// `UTF8_DECOMPOSE` as wallet2 wires it: ASCII input is copied (and cut at
    /// 359 bytes); anything else goes through utf8proc NFKD, which fails above
    /// 359 code points or 360 bytes. Returns the C string, or nil on failure.
    static func decompose(_ str: String) -> [Int8]? {
        let utf8 = Array(str.utf8)
        if utf8.contains(where: { $0 >= 0x80 }) {
            let nfkd = str.decomposedStringWithCompatibilityMapping
            if nfkd.unicodeScalars.count > strSize - 1 { return nil }
            if nfkd.utf8.count > strSize { return nil }
            return cString(nfkd)
        }
        var bytes = utf8.prefix(strSize - 1).map { Int8(bitPattern: $0) }
        bytes.append(0)
        return bytes
    }

    /// `str_split`: split a C string on ' ' into at most 16 words. Returns the
    /// words (each 0-terminated) and the count the C code returns (17 means
    /// "too many").
    static func split(_ str: [Int8]) -> (words: [[Int8]], count: Int) {
        var words: [[Int8]] = []
        var pos = 0
        var word: [Int8] = []
        var w = 0
        let space = Int8(UInt8(ascii: " "))
        while str[pos] != 0 {
            word = []
            while str[pos] != 0 && str[pos] != space {
                word.append(str[pos])
                pos += 1
            }
            word.append(0)
            words.append(word)
            if str[pos] != 0 {
                pos += 1
            }
            w += 1
            if w == wordCount {
                if str[pos] != 0 {
                    w += 1
                }
                break
            }
        }
        return (words, w)
    }

    // MARK: - Decode

    /// `polyseed_decode(str, coin, &lang, &seed)`.
    static func decode(_ phrase: String, coin: UInt16 = coinMonero,
                       lists: [PolyseedWordlist] = SeedWordlists.polyseed) -> Status {
        guard let normalized = decompose(phrase) else { return .errNormalization }
        let split = split(normalized)
        guard split.count == wordCount else { return .errNumWords }

        // polyseed_phrase_decode
        var found: (language: Int, indices: [Int])?
        for (li, list) in lists.enumerated() {
            var indices: [Int] = []
            var success = true
            for word in split.words {
                guard let value = search(word, in: list) else {
                    success = false
                    break
                }
                indices.append(value)
            }
            if !success { continue }
            if found != nil { return .errMultLang }
            found = (li, indices)
        }
        guard let found else { return .errLang }
        return finish(indices: found.indices, language: found.language, coin: coin)
    }

    /// `polyseed_decode_explicit`.
    static func decodeExplicit(_ phrase: String, language: Int, coin: UInt16 = coinMonero,
                               lists: [PolyseedWordlist] = SeedWordlists.polyseed) -> Status {
        guard let normalized = decompose(phrase) else { return .errNormalization }
        let split = split(normalized)
        guard split.count == wordCount else { return .errNumWords }
        var indices: [Int] = []
        for word in split.words {
            guard let value = search(word, in: lists[language]) else { return .errLang }
            indices.append(value)
        }
        return finish(indices: indices, language: language, coin: coin)
    }

    private static func finish(indices: [Int], language: Int, coin: UInt16) -> Status {
        var coeff = indices.map { UInt16($0) }
        coeff[1] ^= coin
        guard polyEval(coeff) == 0 else { return .errChecksum }
        let data = polyToData(coeff)
        guard data.features & reservedFeatures == 0 else { return .errUnsupported }
        return .ok(language: language, indices: indices, data: data)
    }

    // MARK: - GF(2048)

    /// `gf_elem_mul2`
    static func mul2(_ x: UInt16) -> UInt16 {
        if x < 1024 { return 2 * x }
        return mul2Table[Int(x % 8)] + 16 * ((x - 1024) / 8)
    }

    /// `gf_poly_eval`: Horner's method at x = 2.
    static func polyEval(_ coeff: [UInt16]) -> UInt16 {
        var result = coeff[wordCount - 1]
        var i = wordCount - 2
        while i >= 0 {
            result = mul2(result) ^ coeff[i]
            i -= 1
        }
        return result
    }

    /// `polyseed_poly_to_data`
    static func polyToData(_ coeff: [UInt16]) -> SeedData {
        var secret = [UInt8](repeating: 0, count: 32)
        var extraVal: UInt = 0
        var extraBits = 0
        var secretIdx = 0
        var secretBits = 0
        var seedBits = 0

        for i in 1..<wordCount {
            var wordVal = UInt(coeff[i])
            extraVal <<= 1
            extraVal |= wordVal & 1
            wordVal >>= 1
            var wordBits = gfBits - 1
            extraBits += 1

            while wordBits > 0 {
                if secretBits == 8 {
                    secretIdx += 1
                    seedBits += secretBits
                    secretBits = 0
                }
                let chunkBits = min(wordBits, 8 - secretBits)
                wordBits -= chunkBits
                let chunkMask = UInt((1 << chunkBits) - 1)
                if chunkBits < 8 {
                    secret[secretIdx] = UInt8(truncatingIfNeeded: UInt(secret[secretIdx]) << chunkBits)
                }
                secret[secretIdx] |= UInt8(truncatingIfNeeded: (wordVal >> wordBits) & chunkMask)
                secretBits += chunkBits
            }
        }
        seedBits += secretBits
        assert(seedBits == secretBitCount)
        assert(extraBits == featureBits + dateBits)

        return SeedData(
            birthday: extraVal & dateMask,
            features: extraVal >> dateBits,
            secret: secret,
            checksum: coeff[0]
        )
    }

    /// `polyseed_data_to_poly` plus `gf_poly_encode`, for tests: builds the 16
    /// word indices of `data` with a fresh checksum. `coin` is applied as
    /// `polyseed_encode` applies it.
    static func encode(_ data: SeedData, coin: UInt16 = coinMonero) -> [Int] {
        var coeff = [UInt16](repeating: 0, count: wordCount)
        let extraVal = (data.features << dateBits) | data.birthday
        var extraBits = featureBits + dateBits
        var wordBits = 0
        var wordVal: UInt = 0
        var secretIdx = 0
        var secretVal = UInt(data.secret[secretIdx])
        var secretBitsLeft = 8
        var seedRemBits = secretBitCount - 8
        let shareBits = 10

        for i in 0..<(wordCount - 1) {
            while wordBits < shareBits {
                if secretBitsLeft == 0 {
                    secretIdx += 1
                    secretBitsLeft = min(seedRemBits, 8)
                    secretVal = UInt(data.secret[secretIdx])
                    seedRemBits -= secretBitsLeft
                }
                let chunkBits = min(secretBitsLeft, shareBits - wordBits)
                secretBitsLeft -= chunkBits
                wordBits += chunkBits
                wordVal <<= chunkBits
                wordVal |= (secretVal >> secretBitsLeft) & UInt((1 << chunkBits) - 1)
            }
            wordVal <<= 1
            extraBits -= 1
            wordVal |= (extraVal >> extraBits) & 1
            coeff[1 + i] = UInt16(wordVal)
            wordVal = 0
            wordBits = 0
        }
        coeff[0] = 0
        coeff[0] = polyEval(coeff)
        coeff[1] ^= coin
        return coeff.map { Int($0) }
    }

    // MARK: - Birthday

    /// `birthday_decode`
    static func birthdayDecode(_ birthday: UInt) -> UInt64 {
        epoch + UInt64(birthday) * timeStep
    }
}
