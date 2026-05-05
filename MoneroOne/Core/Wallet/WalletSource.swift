import Foundation

/// The origin of a wallet's keys — determines how it's unlocked, where it
/// can sign, and how the unlock flow has to be staged.
///
/// Codable format is a string for the seed/viewOnly cases (matches the
/// legacy `seedType: String` field on disk) and a tagged-string for
/// hardware cases ("hardware:trezor:<deviceId>:<peripheralUUID?>").
/// Existing single-source installs continue to decode unchanged.
enum WalletSource: Codable, Equatable {
    case seed(SeedType)
    case viewOnly
    case hardware(HardwareWallet)

    enum SeedType: String, Codable, Equatable {
        case polyseed
        case bip39
        case legacy
    }

    enum DecodeError: Error {
        case unknownSource(String)
    }

    /// Whether the wallet holds a spend key on-device and can produce
    /// signed transactions without consulting an external device.
    /// View-only and hardware wallets return `false` — hardware wallets
    /// can sign, but only by handing off to the device through a
    /// reconnect session.
    var canSignLocally: Bool {
        switch self {
        case .seed: return true
        case .viewOnly, .hardware: return false
        }
    }

    /// Raw on-disk form. Backwards-compatible with the legacy
    /// `seedType: String` field for the existing cases, extended with a
    /// tagged form for hardware bindings.
    var rawString: String {
        switch self {
        case .seed(let type): return type.rawValue
        case .viewOnly: return "viewOnly"
        case .hardware(let hw): return "hardware:" + hw.rawString
        }
    }

    init(rawString raw: String) throws {
        switch raw {
        case "polyseed": self = .seed(.polyseed)
        case "bip39":    self = .seed(.bip39)
        case "legacy":   self = .seed(.legacy)
        case "viewOnly": self = .viewOnly
        default:
            if raw.hasPrefix("hardware:") {
                let suffix = String(raw.dropFirst("hardware:".count))
                self = .hardware(try HardwareWallet(rawString: suffix))
            } else {
                throw DecodeError.unknownSource(raw)
            }
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

/// A wallet whose spend key lives on an external signer. Each vendor
/// gets its own associated value because their bindings differ — Trezor
/// pairs over BLE and tracks a peripheral UUID, Ledger pairs over USB
/// and won't have one.
enum HardwareWallet: Codable, Equatable {
    case trezor(TrezorBinding)
    // case ledger(LedgerBinding)  // future

    var rawString: String {
        switch self {
        case .trezor(let b): return "trezor:" + b.rawString
        }
    }

    init(rawString raw: String) throws {
        if raw.hasPrefix("trezor:") {
            let body = String(raw.dropFirst("trezor:".count))
            self = .trezor(try TrezorBinding(rawString: body))
        } else {
            throw WalletSource.DecodeError.unknownSource("hardware:" + raw)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = try HardwareWallet(rawString: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}

/// Binding to a paired Trezor. The `model` is display-only ("Safe 7"),
/// `deviceId` is the THP-supplied identifier that survives BLE
/// reconnection, and `peripheralUUID` is the last-known CoreBluetooth
/// peripheral identifier so reconnect can skip scanning when possible.
///
/// Encoded as `<model>|<deviceId>|<peripheralUUID?>` so the whole
/// `WalletSource` round-trips through a single Codable string. Newlines
/// and pipes are forbidden in `model`/`deviceId` (they're THP-derived
/// hex/printable so this is safe in practice).
struct TrezorBinding: Codable, Equatable {
    let model: String
    let deviceId: String
    let peripheralUUID: String?

    var rawString: String {
        let parts = [model, deviceId, peripheralUUID ?? ""]
        return parts.joined(separator: "|")
    }

    init(model: String, deviceId: String, peripheralUUID: String? = nil) {
        self.model = model
        self.deviceId = deviceId
        self.peripheralUUID = peripheralUUID
    }

    init(rawString raw: String) throws {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw WalletSource.DecodeError.unknownSource("hardware:trezor:" + raw)
        }
        self.model = parts[0]
        self.deviceId = parts[1]
        self.peripheralUUID = parts[2].isEmpty ? nil : parts[2]
    }
}
