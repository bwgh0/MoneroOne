import Foundation

struct PriceAlert: Codable, Identifiable {
    let id: UUID
    var targetPrice: Double
    var alertType: AlertType
    var currency: String
    var isEnabled: Bool
    var lastTriggeredAt: Date?
    let createdAt: Date

    enum AlertType: String, Codable {
        case above
        case below
    }

    init(
        id: UUID = UUID(),
        targetPrice: Double,
        alertType: AlertType,
        currency: String,
        isEnabled: Bool = true,
        lastTriggeredAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetPrice = targetPrice
        self.alertType = alertType
        self.currency = currency
        self.isEnabled = isEnabled
        self.lastTriggeredAt = lastTriggeredAt
        self.createdAt = createdAt
    }

    var isOnCooldown: Bool {
        guard let lastTriggered = lastTriggeredAt else { return false }
        return Date().timeIntervalSince(lastTriggered) < PriceAlertService.cooldownInterval
    }

    var cooldownTimeRemaining: TimeInterval {
        guard let lastTriggered = lastTriggeredAt else { return 0 }
        let elapsed = Date().timeIntervalSince(lastTriggered)
        return max(0, PriceAlertService.cooldownInterval - elapsed)
    }
}

@MainActor
class PriceAlertService: ObservableObject {
    @Published var alerts: [PriceAlert] = []

    nonisolated static let cooldownInterval: TimeInterval = 3600 // 1 hour
    private static let storageKey = "priceAlerts"

    init() {
        loadAlerts()
    }

    func addAlert(type: PriceAlert.AlertType, targetPrice: Double, currency: String) {
        let alert = PriceAlert(
            targetPrice: targetPrice,
            alertType: type,
            currency: currency
        )
        alerts.append(alert)
        saveAlerts()
    }

    func removeAlert(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        saveAlerts()
    }

    func toggleAlert(_ alert: PriceAlert) {
        guard let index = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[index].isEnabled.toggle()
        saveAlerts()
    }

    func checkAlerts(currentPrice: Double, currency: String) -> [PriceAlert] {
        var triggeredAlerts: [PriceAlert] = []

        for (index, alert) in alerts.enumerated() {
            guard alert.isEnabled,
                  alert.currency == currency,
                  !alert.isOnCooldown else { continue }

            var shouldTrigger = false

            switch alert.alertType {
            case .above:
                shouldTrigger = currentPrice >= alert.targetPrice
            case .below:
                shouldTrigger = currentPrice <= alert.targetPrice
            }

            if shouldTrigger {
                alerts[index].lastTriggeredAt = Date()
                triggeredAlerts.append(alerts[index])
            }
        }

        if !triggeredAlerts.isEmpty {
            saveAlerts()
        }

        return triggeredAlerts
    }

    func saveAlerts() {
        do {
            let data = try JSONEncoder().encode(alerts)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            print("Failed to save price alerts: \(error)")
        }
    }

    func loadAlerts() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            alerts = try JSONDecoder().decode([PriceAlert].self, from: data)
        } catch {
            print("Failed to load price alerts: \(error)")
        }
    }
}
