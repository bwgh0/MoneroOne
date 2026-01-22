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
            print("Failed to request notification permission: \(error)")
            return false
        }
    }

    func hasPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    func sendAlert(_ alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = "XMR Price Alert"

        let currencySymbol = PriceService.currencySymbols[alert.currency] ?? "$"
        let direction = alert.alertType == .above ? "above" : "below"
        let formattedTarget = String(format: "%.2f", alert.targetPrice)
        let formattedCurrent = String(format: "%.2f", currentPrice)

        content.body = "Monero is now \(direction) \(currencySymbol)\(formattedTarget) (currently \(currencySymbol)\(formattedCurrent))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "priceAlert-\(alert.id.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send price alert notification: \(error)")
            }
        }
    }
}
