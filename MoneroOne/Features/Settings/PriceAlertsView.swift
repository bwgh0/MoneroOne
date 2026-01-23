import SwiftUI

struct PriceAlertsView: View {
    @ObservedObject var priceAlertService: PriceAlertService
    @ObservedObject var priceService: PriceService
    @State private var showAddAlert = false
    @State private var hasNotificationPermission = false

    var body: some View {
        List {
            if !hasNotificationPermission {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications Disabled")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Enable notifications to receive price alerts")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Enable") {
                            Task {
                                hasNotificationPermission = await PriceAlertNotificationManager.shared.requestPermission()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            if priceAlertService.alerts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Price Alerts")
                            .font(.headline)
                        Text("Add your first alert to get notified when XMR crosses a price threshold")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(priceAlertService.alerts) { alert in
                        AlertRow(
                            alert: alert,
                            onToggle: { priceAlertService.toggleAlert(alert) }
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let alert = priceAlertService.alerts[index]
                            priceAlertService.removeAlert(alert)
                        }
                    }
                } header: {
                    Text("Active Alerts")
                } footer: {
                    Text("Alerts trigger at most once per hour")
                }
            }

            Section {
                Button {
                    showAddAlert = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                        Text("Add Alert")
                            .foregroundColor(.primary)
                    }
                }
            }

            if let price = priceService.xmrPrice {
                Section("Current Price") {
                    HStack {
                        Text("1 XMR")
                        Spacer()
                        Text("\(priceService.currencySymbol)\(String(format: "%.2f", price))")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .navigationTitle("Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddAlert) {
            AddPriceAlertView(
                priceAlertService: priceAlertService,
                priceService: priceService
            )
        }
        .task {
            hasNotificationPermission = await PriceAlertNotificationManager.shared.hasPermission()
        }
    }
}

struct AlertRow: View {
    let alert: PriceAlert
    let onToggle: () -> Void

    private var currencySymbol: String {
        PriceService.currencySymbols[alert.currency] ?? "$"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: alert.alertType == .above ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundColor(alert.alertType == .above ? .green : .red)

                    Text("\(alert.alertType == .above ? "Above" : "Below") \(currencySymbol)\(String(format: "%.2f", alert.targetPrice))")
                        .fontWeight(.medium)
                }

                if alert.isOnCooldown {
                    let remaining = Int(alert.cooldownTimeRemaining / 60)
                    Text("Triggered \(60 - remaining)m ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(alert.currency.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { alert.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(.orange)
        }
        .opacity(alert.isEnabled ? 1.0 : 0.6)
    }
}

#Preview {
    NavigationStack {
        PriceAlertsView(
            priceAlertService: PriceAlertService(),
            priceService: PriceService()
        )
    }
}
