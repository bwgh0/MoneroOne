import SwiftUI

enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceAlertService: PriceAlertService
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @State private var showBackup = false
    @State private var showSecurity = false
    @State private var showDeleteConfirmation = false
    @State private var showResetSyncConfirmation = false

    private var syncStatusText: String {
        switch walletManager.syncState {
        case .synced: return "Synced"
        case .syncing(let progress, _): return "\(Int(progress))%"
        case .connecting: return "Connecting"
        case .error: return "Error"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Wallet Section
                Section("Wallet") {
                    NavigationLink {
                        BackupView()
                    } label: {
                        SettingsRow(
                            icon: "key.fill",
                            title: "Backup Seed Phrase",
                            color: .orange
                        )
                    }
                    .accessibilityIdentifier("settings.backupRow")

                    NavigationLink {
                        SecurityView()
                    } label: {
                        SettingsRow(
                            icon: "lock.shield",
                            title: "Security",
                            color: .blue
                        )
                    }
                    .accessibilityIdentifier("settings.securityRow")
                }

                // Display Section
                Section("Display") {
                    Picker(selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRow(
                            icon: "circle.lefthalf.filled",
                            title: "Appearance",
                            color: .indigo
                        )
                    }

                    NavigationLink {
                        CurrencySettingsView(priceService: priceService)
                    } label: {
                        HStack {
                            SettingsRow(
                                icon: "dollarsign.circle",
                                title: "Currency",
                                color: .green
                            )
                            Spacer()
                            Text(priceService.selectedCurrency.uppercased())
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Currency, \(priceService.selectedCurrency.uppercased())")
                        .accessibilityHint("Change display currency")
                    }

                    NavigationLink {
                        PriceAlertsView(
                            priceAlertService: priceAlertService,
                            priceService: priceService
                        )
                    } label: {
                        HStack {
                            SettingsRow(
                                icon: "bell.badge",
                                title: "Price Alerts",
                                color: .pink
                            )
                            Spacer()
                            if !priceAlertService.alerts.isEmpty {
                                Text("\(priceAlertService.alerts.filter { $0.isEnabled }.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Price Alerts, \(priceAlertService.alerts.filter { $0.isEnabled }.count) active")
                        .accessibilityHint("View and manage price alerts")
                    }

                    NavigationLink {
                        WidgetSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "square.stack.3d.up.fill",
                            title: "Home Screen Widget",
                            color: .blue
                        )
                    }
                }

                // Sync Section
                Section("Sync") {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        HStack {
                            SettingsRow(
                                icon: "arrow.triangle.2.circlepath",
                                title: "Sync Settings",
                                color: .orange
                            )
                            Spacer()
                            Text(syncStatusText)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Sync Settings, status \(syncStatusText)")
                    }
                    .accessibilityIdentifier("settings.syncRow")
                }

                // About Section
                Section("About") {
                    HStack {
                        SettingsRow(
                            icon: "info.circle",
                            title: "Build",
                            color: .gray
                        )
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Build number, \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")

                    Link(destination: URL(string: "https://monero.one")!) {
                        SettingsRow(
                            icon: "globe",
                            title: "Website",
                            color: .orange
                        )
                    }
                    .accessibilityHint("Opens monero.one in your browser")

                    Link(destination: URL(string: "https://monero.one/privacy")!) {
                        SettingsRow(
                            icon: "hand.raised.fill",
                            title: "Privacy Policy",
                            color: .blue
                        )
                    }
                    .accessibilityHint("Opens privacy policy in your browser")

                    Link(destination: URL(string: "https://monero.one/terms")!) {
                        SettingsRow(
                            icon: "doc.text.fill",
                            title: "Terms of Service",
                            color: .gray
                        )
                    }
                    .accessibilityHint("Opens terms of service in your browser")
                }

                // Support the Developer Section
                Section("Support the Developer") {
                    NavigationLink {
                        DonationView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .font(.body)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.pink, .orange, .yellow],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 28, height: 28)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(6)

                            Text("Donate XMR")
                                .foregroundColor(.orange)
                                .fontWeight(.medium)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Donate XMR")
                        .accessibilityHint("Support the developer with a Monero donation")
                    }
                }

                // Danger Zone
                Section {
                    Button(role: .destructive) {
                        showResetSyncConfirmation = true
                    } label: {
                        SettingsRow(
                            icon: "arrow.counterclockwise",
                            title: "Reset Sync Data",
                            color: .orange
                        )
                    }
                    .accessibilityHint("Clears all sync progress and re-syncs from the beginning")

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRow(
                            icon: "trash",
                            title: "Remove Wallet from Device",
                            color: .red
                        )
                    }
                    .accessibilityHint("Removes wallet data from this device. Recovery with seed phrase is still possible.")
                }
            }
            .navigationTitle("Settings")
            .alert("Reset Sync Data?", isPresented: $showResetSyncConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    walletManager.resetSyncData()
                }
            } message: {
                Text("This will clear all sync progress and re-sync from the beginning. Your wallet and keys are not affected.")
            }
            .alert("Remove Wallet from Device?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Remove", role: .destructive) {
                    walletManager.deleteWallet()
                }
            } message: {
                Text("This removes wallet data from this device only. Your wallet still exists on the blockchain and can be recovered with your seed phrase.")
            }
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .cornerRadius(6)

            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
