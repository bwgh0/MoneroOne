import Foundation

struct WalletInfo: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var emoji: String
    /// Which origin the wallet's keys came from. Codable-compatible with the
    /// legacy `seedType: String` field — existing installs decode via the
    /// same key ("seedType") and the `WalletSource` enum parses the string.
    let source: WalletSource
    let createdAt: Date
    var restoreHeight: UInt64
    var syncResetCount: Int
    var userCreatedSubaddressIndices: [Int]
    var cachedPrimaryAddress: String?
    var cachedBalance: Decimal?

    var keychainPrefix: String { "one.monero.MoneroOne.wallet.\(id.uuidString)" }

    /// Convenience — true when the wallet was opened from address + view key.
    var isViewOnly: Bool { source == .viewOnly }

    enum CodingKeys: String, CodingKey {
        // Persisted as "seedType" for backwards compatibility with multi-wallet
        // installs created before WalletSource existed.
        case id, name, emoji
        case source = "seedType"
        case createdAt, restoreHeight
        case syncResetCount, userCreatedSubaddressIndices
        case cachedPrimaryAddress, cachedBalance
    }

    init(id: UUID, name: String, emoji: String = "\u{1F4B0}", source: WalletSource, createdAt: Date, restoreHeight: UInt64, syncResetCount: Int, userCreatedSubaddressIndices: [Int], cachedPrimaryAddress: String?, cachedBalance: Decimal?) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.source = source
        self.createdAt = createdAt
        self.restoreHeight = restoreHeight
        self.syncResetCount = syncResetCount
        self.userCreatedSubaddressIndices = userCreatedSubaddressIndices
        self.cachedPrimaryAddress = cachedPrimaryAddress
        self.cachedBalance = cachedBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "\u{1F4B0}"
        source = try container.decode(WalletSource.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        restoreHeight = try container.decode(UInt64.self, forKey: .restoreHeight)
        syncResetCount = try container.decode(Int.self, forKey: .syncResetCount)
        userCreatedSubaddressIndices = try container.decode([Int].self, forKey: .userCreatedSubaddressIndices)
        cachedPrimaryAddress = try container.decodeIfPresent(String.self, forKey: .cachedPrimaryAddress)
        cachedBalance = try container.decodeIfPresent(Decimal.self, forKey: .cachedBalance)
    }
}
