import Foundation
import UserNotifications

class PriceAlertNotificationManager {
    static let shared = PriceAlertNotificationManager()

    private init() {}

    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            return granted
        } catch {
            return false
        }
    }

    func hasPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    func sendAlert(_ alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "XMR Price Alert")

        let currencySymbol = PriceService.currencySymbols[alert.currency] ?? "$"
        let target = "\(currencySymbol)\(String(format: "%.2f", alert.targetPrice))"
        let current = "\(currencySymbol)\(String(format: "%.2f", currentPrice))"

        content.body = alert.alertType == .above
            ? String(localized: "Monero is now above \(target) (currently \(current))", comment: "Price alert: target price, then the price now")
            : String(localized: "Monero is now below \(target) (currently \(current))", comment: "Price alert: target price, then the price now")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "priceAlert-\(alert.id.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}
