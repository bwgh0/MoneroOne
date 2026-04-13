import Foundation

struct WalletInfo: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var emoji: String
    let seedType: String            // "polyseed", "bip39", "legacy"
    let createdAt: Date
    var restoreHeight: UInt64
    var syncResetCount: Int
    var userCreatedSubaddressIndices: [Int]
    var cachedPrimaryAddress: String?
    var cachedBalance: Decimal?

    var keychainPrefix: String { "one.monero.MoneroOne.wallet.\(id.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, seedType, createdAt, restoreHeight
        case syncResetCount, userCreatedSubaddressIndices
        case cachedPrimaryAddress, cachedBalance
    }

    init(id: UUID, name: String, emoji: String = "\u{1F4B0}", seedType: String, createdAt: Date, restoreHeight: UInt64, syncResetCount: Int, userCreatedSubaddressIndices: [Int], cachedPrimaryAddress: String?, cachedBalance: Decimal?) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.seedType = seedType
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
        seedType = try container.decode(String.self, forKey: .seedType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        restoreHeight = try container.decode(UInt64.self, forKey: .restoreHeight)
        syncResetCount = try container.decode(Int.self, forKey: .syncResetCount)
        userCreatedSubaddressIndices = try container.decode([Int].self, forKey: .userCreatedSubaddressIndices)
        cachedPrimaryAddress = try container.decodeIfPresent(String.self, forKey: .cachedPrimaryAddress)
        cachedBalance = try container.decodeIfPresent(Decimal.self, forKey: .cachedBalance)
    }
}
