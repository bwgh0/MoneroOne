import Foundation
import MoneroKit

// OpenAlias names on the Send screen: the pure rules, with no I/O except the
// pin store. The OpenAlias send spec (2026-09-27) sections 3.7 and 4 give
// every rule here.

/// What the text in the recipient field is.
enum RecipientInput: Equatable {
    case empty
    case address(String)
    case name(OpenAliasName)
    /// `monero.one`, a name under it, or the `@name` shorthand: saved for
    /// Monero One names, so the app sends no lookup. Monero One's own names,
    /// such as `donate@monero.one`, resolve as names.
    case reserved
    case invalidName
}

/// An OpenAlias name. `display` is the text the user typed, in lowercase,
/// with its `@` kept. `query` is the DNS name the app looks up.
struct OpenAliasName: Equatable {
    let display: String
    let query: String
    var isUsername: Bool {
        query.hasSuffix(".monero.one") && !OpenAlias.isOperatorName(display)
    }
}

enum AddressCheck {
    case valid
    case otherNetwork
    case invalid
}

enum DnssecStatus: Equatable {
    /// The kit proved the answer with signatures that chain to the root.
    case valid
    /// The kit proved that the zone has no DNSSEC signatures.
    case off
}

enum OpenAliasFailure: Error, Equatable {
    case usernameUnavailable, usernameVerification, usernameStale, usernameNotConfigured
    case noRecord
    case severalAddresses
    case paymentID
    case invalidAddress
    case wrongNetwork
    case dnssecFailed
    case timeout
    case network
    case tor
}

struct OpenAliasResult: Equatable {
    let address: String
    /// The sanitized `recipient_name`: the title of the recipient card and
    /// the review step (founder, 2026-10-01). `monero:` links still drop
    /// it (`MoneroPaymentURI`).
    let recipientName: String?
    /// The sanitized `tx_description`: a row on the review step.
    var txDescription: String? = nil
    let dnssec: DnssecStatus
    var usernameTrust: UsernameTrust? = nil
    var verificationText: String { usernameTrust?.text ?? dnssec.text }
}

enum PinState: Equatable {
    /// No address was paid for this name on this network.
    case none
    /// The address equals the address of the last payment, made on this date.
    case same(Date)
    /// The address differs from the address of the last payment.
    case changed(Date)
}

enum OpenAlias {

    // MARK: - Classify (section 4.1)

    private static let blockedTopLevel: Set<String> = ["onion", "local", "localhost", "invalid", "arpa"]

    static func classify(_ raw: String) -> RecipientInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.prefix(7).lowercased() == "monero:" { return .address(text) }

        let hasDot = text.contains(".")
        let hasAt = text.contains("@")
        if !hasDot && !hasAt { return .address(text) }
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return .invalidName }

        if !isOperatorName(text.lowercased()), let local = UsernameRecipient.localPart(text) {
            if isOperatorName(local + "@monero.one") { return .reserved }
            return .name(OpenAliasName(display: "@" + local, query: local + ".monero.one"))
        }
        if text.hasPrefix("@") { return .invalidName }

        var display = text.lowercased()
        if display.hasSuffix(".") { display.removeLast() }

        let sides = display.split(separator: "@", omittingEmptySubsequences: false)
        let query: String
        switch sides.count {
        case 1:
            query = display
        case 2:
            guard !sides[0].isEmpty, !sides[1].isEmpty else { return .invalidName }
            query = String(sides[0]) + "." + String(sides[1])
        default:
            return .invalidName
        }

        guard isValidQueryName(query) else { return .invalidName }
        if query == operatorDomain || query.hasSuffix("." + operatorDomain), !isOperatorName(display) {
            return .reserved
        }
        return .name(OpenAliasName(display: display, query: query))
    }

    // MARK: - Monero One's own names (exception to D8)

    private static let operatorDomain = "monero.one"

    /// The names under monero.one that resolve like any other name, in the
    /// `name@monero.one` form only. Monero One publishes these records
    /// itself. Every other monero.one name stays reserved (D8), so no record
    /// can pose as the Monero One team.
    private static let operatorNames: Set<String> = ["donate"]

    /// True for one of Monero One's own names, such as `donate@monero.one`.
    /// `display` is the lowercase name, as `classify` makes it.
    static func isOperatorName(_ display: String) -> Bool {
        let sides = display.split(separator: "@", omittingEmptySubsequences: false)
        guard sides.count == 2, sides[1] == operatorDomain else { return false }
        return operatorNames.contains(String(sides[0]))
    }

    /// Labels of 1 to 63 characters from `a-z`, `0-9`, `_` and `-`, no `-` at
    /// either end, 2 or more labels, 253 characters at most, and a top label
    /// of letters only (2 or more) or punycode.
    private static func isValidQueryName(_ name: String) -> Bool {
        guard name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.utf8.count),
                  label.utf8.allSatisfy(isLabelByte),
                  label.first != "-", label.last != "-" else { return false }
        }
        guard let top = labels.last else { return false }
        let lettersOnly = top.utf8.count >= 2 && top.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }
        guard lettersOnly || top.hasPrefix("xn--") else { return false }
        return !blockedTopLevel.contains(String(top))
    }

    private static func isLabelByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
    }

    // MARK: - TXT RDATA (section 4.2)

    /// The text of one TXT record: its character-strings joined with no
    /// separator. Nil drops the record (bad hex, empty RDATA, a length byte
    /// that runs past the end, or bad UTF-8).
    static func decodeTXT(hex: String) -> String? {
        guard let bytes = bytes(fromHex: hex), !bytes.isEmpty else { return nil }
        var joined: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count else { return nil }
            joined.append(contentsOf: bytes[index..<(index + length)])
            index += length
        }
        return strictUTF8(joined)
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Strict UTF-8: any bad sequence gives nil (no replacement characters).
    private static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    // MARK: - OA1 record (section 4.3)

    /// The keys of one `oa1:xmr` record that the app reads.
    struct Record: Equatable {
        /// Every `recipient_address` value, in record order.
        var addresses: [String] = []
        var recipientName: String?
        var txDescription: String?
        var paymentID: String?
    }

    /// Nil when the text is not an `oa1:xmr` record or the record is malformed.
    static func parseRecord(_ text: String) -> Record? {
        let s = Array(text.unicodeScalars)
        guard s.count > 7,
              String(String.UnicodeScalarView(s[0..<7])).lowercased() == "oa1:xmr",
              s[7] == " " else { return nil }

        var record = Record()
        var i = 8
        while true {
            while i < s.count, s[i] == " " { i += 1 }
            if i >= s.count { break }

            // The key runs to `=`. A segment with no `=` before its `;` is skipped.
            var end = i
            while end < s.count, s[end] != "=", s[end] != ";" { end += 1 }
            if end >= s.count { break }
            if s[end] == ";" {
                i = end + 1
                continue
            }
            let key = trimSpaces(String(String.UnicodeScalarView(s[i..<end]))).lowercased()
            i = end + 1

            while i < s.count, s[i] == " " { i += 1 }
            var value = String.UnicodeScalarView()
            if i < s.count, s[i] == "\"" {
                // Quoted: runs to the next `"` with no `\` before it.
                i += 1
                var closed = false
                while i < s.count {
                    if s[i] == "\\" {
                        guard i + 1 < s.count else { i += 1; break }
                        value.append(s[i + 1])
                        i += 2
                    } else if s[i] == "\"" {
                        closed = true
                        i += 1
                        break
                    } else {
                        value.append(s[i])
                        i += 1
                    }
                }
                guard closed else { return nil }
                while i < s.count, s[i] == " " { i += 1 }
                if i < s.count {
                    guard s[i] == ";" else { return nil }
                    i += 1
                }
                store(key: key, value: String(value), in: &record)
            } else {
                // Plain: runs to the next `;` with no `\` before it.
                while i < s.count, s[i] != ";" {
                    if s[i] == "\\" {
                        if i + 1 < s.count { value.append(s[i + 1]) }
                        i += 2
                    } else {
                        value.append(s[i])
                        i += 1
                    }
                }
                if i < s.count { i += 1 }
                store(key: key, value: trimSpaces(String(value)), in: &record)
            }
        }
        return record
    }

    private static func store(key: String, value: String, in record: inout Record) {
        switch key {
        case "recipient_address":
            record.addresses.append(value)
        case "recipient_name":
            if record.recipientName == nil { record.recipientName = value }
        case "tx_description":
            if record.txDescription == nil { record.txDescription = value }
        case "tx_payment_id":
            if record.paymentID == nil { record.paymentID = value }
        default:
            break
        }
    }

    private static func trimSpaces(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    // MARK: - Select (section 4.4)

    static func select(_ records: [Record], dnssec: DnssecStatus,
                       check: (String) -> AddressCheck) -> Result<OpenAliasResult, OpenAliasFailure> {
        let addresses = Set(records.flatMap(\.addresses).filter { !$0.isEmpty })
        guard !addresses.isEmpty else { return .failure(.noRecord) }
        guard addresses.count == 1, let address = addresses.first else { return .failure(.severalAddresses) }
        if records.contains(where: { !($0.paymentID ?? "").isEmpty }) { return .failure(.paymentID) }

        switch check(address) {
        case .valid: break
        case .otherNetwork: return .failure(.wrongNetwork)
        case .invalid: return .failure(.invalidAddress)
        }

        // Records that disagree give no name or description.
        let names = Set(records.compactMap { $0.recipientName.flatMap(sanitizeName) })
        let descriptions = Set(records.compactMap { $0.txDescription.flatMap(sanitizeDescription) })
        return .success(OpenAliasResult(address: address,
                                        recipientName: names.count == 1 ? names.first : nil,
                                        txDescription: descriptions.count == 1 ? descriptions.first : nil,
                                        dnssec: dnssec))
    }

    // MARK: - recipient_name and tx_description (section 4.5)

    static let nameDisplayCap = 64
    static let descriptionDisplayCap = 100

    /// The record name as the app shows it. See `sanitize(_:cap:)`.
    static func sanitizeName(_ raw: String) -> String? {
        sanitize(raw, cap: nameDisplayCap)
    }

    static func sanitizeDescription(_ raw: String) -> String? {
        sanitize(raw, cap: descriptionDisplayCap)
    }

    /// Removes control (Cc) and format (Cf) characters, which include the
    /// bidi overrides and the zero-width characters, and the other
    /// invisible (default-ignorable) characters, such as the Hangul filler.
    /// Turns each run of whitespace into one space, trims, and caps the
    /// length at `cap` characters plus "…". Nil when nothing is left.
    private static func sanitize(_ raw: String, cap: Int) -> String? {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                continue
            default:
                break
            }
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        let text = String(out)
        guard !text.isEmpty else { return nil }
        guard text.count > cap else { return text }
        var kept = String(text.prefix(cap))
        while kept.last == " " { kept.removeLast() }
        return kept + "…"
    }

    // MARK: - Monogram

    /// The initials on the recipient card: the first letter of each of the
    /// first two words of the record name that hold a letter, in capitals
    /// ("Monero Development" gives "MD"). Without such a word, the first
    /// letter of the local part of the name: "D" for donate@getmonero.org,
    /// "G" for getmonero.org. Nil when neither has a letter.
    static func initials(recipientName: String?, display: String) -> String? {
        if let recipientName {
            let letters = recipientName
                .split(whereSeparator: \.isWhitespace)
                .compactMap { $0.first(where: \.isLetter) }
                .prefix(2)
            if !letters.isEmpty { return letters.map(capital).joined() }
        }
        let local = display.contains("@")
            ? display.prefix(while: { $0 != "@" })
            : display.prefix(while: { $0 != "." })
        return local.first(where: \.isLetter).map(capital)
    }

    /// One capital letter. A letter whose capital is two letters ("ß")
    /// stays as it is.
    private static func capital(_ letter: Character) -> String {
        let upper = String(letter).uppercased()
        return upper.count == 1 ? upper : String(letter)
    }

    // MARK: - Answer mapping (section 3.7)

    /// The JSON object of the kit lookup.
    private struct KitAnswer: Decodable {
        let status: String
        let rcode: Int?
        let havedata: Bool?
        let nxdomain: Bool?
        let secure: Bool?
        let bogus: Bool?
        let records: [String]?
    }

    /// Maps the kit JSON and the bridge counts to one outcome. The first
    /// rule that matches wins.
    static func mapAnswer(json: String, synthesizedCount: Int, torOn: Bool,
                          check: (String) -> AddressCheck) -> Result<OpenAliasResult, OpenAliasFailure> {
        let netError: OpenAliasFailure = torOn ? .tor : .network
        guard let data = json.data(using: .utf8),
              let answer = try? JSONDecoder().decode(KitAnswer.self, from: data) else {
            return .failure(netError)
        }
        switch answer.status {
        case "timeout": return .failure(.timeout)
        case "ok": break
        default: return .failure(netError)
        }
        guard let rcode = answer.rcode, let havedata = answer.havedata, let nxdomain = answer.nxdomain,
              let secure = answer.secure, let bogus = answer.bogus, let records = answer.records else {
            return .failure(netError)
        }
        // When the bridge failed a DNSKEY or DS fetch, even an unsigned
        // name comes back bogus.
        if synthesizedCount > 0, bogus || rcode != 0 { return .failure(netError) }
        if bogus { return .failure(.dnssecFailed) }
        if rcode == 3 || nxdomain { return .failure(.noRecord) }
        if rcode != 0 { return .failure(netError) }
        if !havedata || records.isEmpty { return .failure(.noRecord) }

        let parsed = records.compactMap { decodeTXT(hex: $0) }.compactMap(parseRecord)
        return select(parsed, dnssec: secure ? .valid : .off, check: check)
    }
}

// MARK: - Pins (section 4.6)

/// The address of the last successful send to each name, per network. A pin
/// never gives the address: every Send does a fresh lookup and compares.
struct OpenAliasPinStore {
    static let cap = 500

    private struct Pin: Codable {
        let address: String
        /// Unix seconds.
        let pinnedAt: Int64
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for network: NetworkType) -> String {
        switch network {
        case .mainnet: return "openAliasPins.mainnet"
        case .testnet: return "openAliasPins.testnet"
        }
    }

    func state(query: String, address: String, network: NetworkType) -> PinState {
        guard let pin = load(network)[query] else { return .none }
        let date = Date(timeIntervalSince1970: TimeInterval(pin.pinnedAt))
        return pin.address == address ? .same(date) : .changed(date)
    }

    /// Stores the sent address for the name. Above the cap, the oldest go.
    func record(query: String, address: String, network: NetworkType, at date: Date = Date()) {
        var pins = load(network)
        pins[query] = Pin(address: address, pinnedAt: Int64(date.timeIntervalSince1970))
        while pins.count > Self.cap,
              let oldest = pins.filter({ $0.key != query }).min(by: { $0.value.pinnedAt < $1.value.pinnedAt })?.key {
            pins.removeValue(forKey: oldest)
        }
        save(pins, network)
    }

    func clearAll() {
        for network in NetworkType.allCases {
            defaults.removeObject(forKey: Self.key(for: network))
        }
    }

    private func load(_ network: NetworkType) -> [String: Pin] {
        guard let text = defaults.string(forKey: Self.key(for: network)),
              let data = text.data(using: .utf8),
              let pins = try? JSONDecoder().decode([String: Pin].self, from: data) else { return [:] }
        return pins
    }

    private func save(_ pins: [String: Pin], _ network: NetworkType) {
        guard let data = try? JSONEncoder().encode(pins),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: Self.key(for: network))
    }
}
