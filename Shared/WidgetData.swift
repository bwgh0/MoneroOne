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

    // Price widget data (optional - only populated when price widget enabled)
    public var currentPrice: Double?
    public var priceChange24h: Double?
    public var priceCurrency: String?  // "usd", "eur", etc.
    public var priceChartPoints: [Double]?  // Simplified: just Y values for sparkline (~24 points for 24h)
    public var priceHigh24h: Double?
    public var priceLow24h: Double?
    public var priceLastUpdated: Date?

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
        isEnabled: Bool = false,
        currentPrice: Double? = nil,
        priceChange24h: Double? = nil,
        priceCurrency: String? = nil,
        priceChartPoints: [Double]? = nil,
        priceHigh24h: Double? = nil,
        priceLow24h: Double? = nil,
        priceLastUpdated: Date? = nil
    ) {
        self.balance = balance
        self.balanceFormatted = balanceFormatted
        self.fiatBalance = fiatBalance
        self.syncStatus = syncStatus
        self.lastUpdated = lastUpdated
        self.recentTransactions = recentTransactions
        self.isTestnet = isTestnet
        self.isEnabled = isEnabled
        self.currentPrice = currentPrice
        self.priceChange24h = priceChange24h
        self.priceCurrency = priceCurrency
        self.priceChartPoints = priceChartPoints
        self.priceHigh24h = priceHigh24h
        self.priceLow24h = priceLow24h
        self.priceLastUpdated = priceLastUpdated
    }

    // Custom decoder to handle old data without new fields
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

        // Price widget fields (optional, backward compatible)
        currentPrice = try container.decodeIfPresent(Double.self, forKey: .currentPrice)
        priceChange24h = try container.decodeIfPresent(Double.self, forKey: .priceChange24h)
        priceCurrency = try container.decodeIfPresent(String.self, forKey: .priceCurrency)
        priceChartPoints = try container.decodeIfPresent([Double].self, forKey: .priceChartPoints)
        priceHigh24h = try container.decodeIfPresent(Double.self, forKey: .priceHigh24h)
        priceLow24h = try container.decodeIfPresent(Double.self, forKey: .priceLow24h)
        priceLastUpdated = try container.decodeIfPresent(Date.self, forKey: .priceLastUpdated)
    }

    private enum CodingKeys: String, CodingKey {
        case balance, balanceFormatted, fiatBalance, syncStatus, lastUpdated, recentTransactions, isTestnet, isEnabled
        case currentPrice, priceChange24h, priceCurrency, priceChartPoints, priceHigh24h, priceLow24h, priceLastUpdated
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

    /// Placeholder for price widget - no fake prices, will show "unavailable" state
    public static var pricePlaceholder: WidgetData {
        WidgetData(
            balance: 0,
            balanceFormatted: "0.0000",
            fiatBalance: nil,
            syncStatus: .offline,
            lastUpdated: Date(),
            recentTransactions: [],
            isTestnet: false,
            isEnabled: true,
            currentPrice: nil,
            priceChange24h: nil,
            priceCurrency: "usd",
            priceChartPoints: nil,
            priceHigh24h: nil,
            priceLow24h: nil,
            priceLastUpdated: nil
        )
    }
}
