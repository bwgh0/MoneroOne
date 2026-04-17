import Foundation

/// The origin of a wallet's keys — determines how it's unlocked and whether
/// it can sign transactions locally.
///
/// Designed so new wallet kinds (view-only now; hardware wallets later) slot
/// in as new enum cases. `canSignLocally` and the dispatch in
/// `WalletManager.startWallet(from:)` key off this type, not ad-hoc flags.
///
/// Codable format is a plain string — same shape as the legacy
/// `WalletInfo.seedType: String` field, so existing multi-wallet installs
/// decode without migration.
enum WalletSource: Codable, Equatable {
    case seed(SeedType)
    case viewOnly
    // Future hardware wallet cases slot in here with their own associated
    // device identifiers — e.g. `case trezor(deviceId: String)`.

    enum SeedType: String, Codable, Equatable {
        case polyseed
        case bip39
        case legacy
    }

    enum DecodeError: Error {
        case unknownSource(String)
    }

    /// Whether the wallet holds a spend key on-device and can produce signed
    /// transactions without consulting an external device. View-only and
    /// (eventually) hardware wallets return `false`.
    var canSignLocally: Bool {
        switch self {
        case .seed: return true
        case .viewOnly: return false
        }
    }

    /// Raw string form — also the Codable representation, so the on-disk
    /// format stays identical to the old `seedType: String` field.
    var rawString: String {
        switch self {
        case .seed(let type): return type.rawValue
        case .viewOnly: return "viewOnly"
        }
    }

    init(rawString: String) throws {
        switch rawString {
        case "polyseed": self = .seed(.polyseed)
        case "bip39": self = .seed(.bip39)
        case "legacy": self = .seed(.legacy)
        case "viewOnly": self = .viewOnly
        default: throw DecodeError.unknownSource(rawString)
        }
    }

    /// Build a seeded source from a mnemonic word count. Falls back to
    /// polyseed for anything unknown so callers don't have to handle nil.
    static func seeded(wordCount: Int) -> WalletSource {
        switch wordCount {
        case 16: return .seed(.polyseed)
        case 24: return .seed(.bip39)
        case 25: return .seed(.legacy)
        default: return .seed(.polyseed)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            self = try WalletSource(rawString: raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown WalletSource: \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}
