import Foundation
import os.log

private let widgetLog = OSLog(subsystem: "one.monero.MoneroOne", category: "Widget")

/// App Group identifier for sharing data between app and widgets
public let appGroupIdentifier = "group.one.monero.MoneroOne"

/// Shared data model for home screen widgets
public struct WidgetData: Codable {
    public var balance: Decimal
    public var balanceFormatted: String
    public var fiatBalance: String?
    public var syncStatus: SyncStatus
    public var lastUpdated: Date
    public var recentTransactions: [WidgetTransaction]
    public var isTestnet: Bool
    public var isEnabled: Bool

    public enum SyncStatus: String, Codable {
        case synced
        case syncing
        case connecting
        case offline

        public var displayText: String {
            switch self {
            case .synced: return "Synced"
            case .syncing: return "Syncing..."
            case .connecting: return "Connecting..."
            case .offline: return "Offline"
            }
        }

        public var iconName: String {
            switch self {
            case .synced: return "checkmark.circle.fill"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .connecting: return "antenna.radiowaves.left.and.right"
            case .offline: return "wifi.slash"
            }
        }
    }

    public init(
        balance: Decimal = 0,
        balanceFormatted: String = "0.0000",
        fiatBalance: String? = nil,
        syncStatus: SyncStatus = .offline,
        lastUpdated: Date = Date(),
        recentTransactions: [WidgetTransaction] = [],
        isTestnet: Bool = false,
        isEnabled: Bool = false
    ) {
        self.balance = balance
        self.balanceFormatted = balanceFormatted
        self.fiatBalance = fiatBalance
        self.syncStatus = syncStatus
        self.lastUpdated = lastUpdated
        self.recentTransactions = recentTransactions
        self.isTestnet = isTestnet
        self.isEnabled = isEnabled
    }

    // Custom decoder to handle old data without isEnabled field
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = try container.decode(Decimal.self, forKey: .balance)
        balanceFormatted = try container.decode(String.self, forKey: .balanceFormatted)
        fiatBalance = try container.decodeIfPresent(String.self, forKey: .fiatBalance)
        syncStatus = try container.decode(SyncStatus.self, forKey: .syncStatus)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        recentTransactions = try container.decode([WidgetTransaction].self, forKey: .recentTransactions)
        isTestnet = try container.decodeIfPresent(Bool.self, forKey: .isTestnet) ?? false
        // Default to true for existing data (if it was saved, widget was enabled)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case balance, balanceFormatted, fiatBalance, syncStatus, lastUpdated, recentTransactions, isTestnet, isEnabled
    }
}

/// Transaction data for widgets
public struct WidgetTransaction: Codable, Identifiable {
    public var id: String
    public var isIncoming: Bool
    public var amount: Decimal
    public var amountFormatted: String
    public var timestamp: Date
    public var isConfirmed: Bool

    public init(id: String, isIncoming: Bool, amount: Decimal, amountFormatted: String, timestamp: Date, isConfirmed: Bool) {
        self.id = id
        self.isIncoming = isIncoming
        self.amount = amount
        self.amountFormatted = amountFormatted
        self.timestamp = timestamp
        self.isConfirmed = isConfirmed
    }
}

/// Helper to save/load widget data from App Group using file-based storage
/// (More reliable than UserDefaults for App Group sharing on simulator)
public class WidgetDataManager {
    public static let shared = WidgetDataManager()

    private let containerURL: URL?
    private let fileName = "widgetData.json"

    private init() {
        containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        if let url = containerURL {
            os_log("✅ App Group container at: %{public}@", log: widgetLog, type: .info, url.path)
        } else {
            os_log("❌ Failed to get App Group container for: %{public}@", log: widgetLog, type: .error, appGroupIdentifier)
        }
    }

    private var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    public func save(_ data: WidgetData) {
        guard let url = fileURL else {
            os_log("❌ Save failed: No App Group container available", log: widgetLog, type: .error)
            return
        }

        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: url, options: .atomic)
            os_log("✅ Saved data to %{public}@ (enabled=%d, balance=%{public}@)", log: widgetLog, type: .info, url.lastPathComponent, data.isEnabled ? 1 : 0, data.balanceFormatted)
        } catch {
            os_log("❌ Save failed: %{public}@", log: widgetLog, type: .error, error.localizedDescription)
        }
    }

    public func load() -> WidgetData? {
        guard let url = fileURL else {
            os_log("❌ Load failed: No App Group container available", log: widgetLog, type: .error)
            return nil
        }

        os_log("📖 Reading from %{public}@", log: widgetLog, type: .debug, url.path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log("❌ Load failed: File does not exist", log: widgetLog, type: .error)
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WidgetData.self, from: data)
            os_log("✅ Loaded data (enabled=%d)", log: widgetLog, type: .info, decoded.isEnabled ? 1 : 0)
            return decoded
        } catch {
            os_log("❌ Load failed: %{public}@", log: widgetLog, type: .error, error.localizedDescription)
            return nil
        }
    }

    public func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static var placeholder: WidgetData {
        WidgetData(
            balance: 0,
            balanceFormatted: "0.0000",
            fiatBalance: nil,
            syncStatus: .offline,
            lastUpdated: Date(),
            recentTransactions: [],
            isTestnet: false,
            isEnabled: false
        )
    }
}
