import SwiftUI

enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var displayName: String {
        switch self {
        case .system: return String(localized: "System", comment: "Appearance setting: follow the system")
        case .light: return String(localized: "Light", comment: "Appearance setting")
        case .dark: return String(localized: "Dark", comment: "Appearance setting")
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
    @AppStorage(WalletManager.rotateReceiveAddressKey) private var rotateReceiveAddress: Bool = true
    @State private var showBackup = false
    @State private var showSecurity = false
    @State private var showDeleteConfirmation = false
    @State private var showResetSyncConfirmation = false
    @State private var showDiagnosticShare = false
    /// The Language row's value; nil for System.
    @State private var languageChoice = AppLanguageSetting.standard.choice

    private var syncStatusText: String {
        switch walletManager.syncState {
        case .synced: return String(localized: "Synced", comment: "Wallet sync status")
        case .syncing(let progress, _): return "\(Int(progress))%"
        case .connecting: return String(localized: "Connecting", comment: "Wallet sync status")
        case .error: return String(localized: "Error", comment: "Wallet sync status")
        case .idle: return String(localized: "Idle", comment: "Wallet sync status")
        }
    }

    /// Names the wallet: the reset clears only the active one, and with
    /// its cache the transaction keys that no rescan brings back.
    private var resetSyncMessage: Text {
        if let name = walletManager.activeWallet?.name {
            return Text("“\(name)” scans again from its restore height. Transaction keys for its past sends are deleted.")
        }
        return Text("This wallet scans again from its restore height. Transaction keys for its past sends are deleted.")
    }

    var body: some View {
        NavigationStack {
            List {
                // Wallet Section
                Section {
                    if !walletManager.isViewOnly {
                        NavigationLink {
                            BackupView()
                        } label: {
                            SettingsRow(
                                icon: "key.fill",
                                title: "Backup Seed Phrase",
                                color: .brand
                            )
                        }
                        .accessibilityIdentifier("settings.backupRow")
                    }

                    NavigationLink {
                        ExportViewKeyView()
                    } label: {
                        SettingsRow(
                            icon: "eye.fill",
                            title: "Export View Key",
                            color: .purple
                        )
                    }
                    .accessibilityIdentifier("settings.exportViewKeyRow")
                } header: {
                    if let wallet = walletManager.activeWallet {
                        Text(verbatim: "\(wallet.emoji) \(wallet.name)")
                            .textCase(nil)
                            .accessibilityLabel("Wallet: \(wallet.name)")
                    } else {
                        Text("Wallet")
                    }
                }

                Section {
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

                    Toggle(isOn: $rotateReceiveAddress) {
                        SettingsRow(
                            icon: "qrcode",
                            title: "Fresh Receive Address",
                            color: .cyan
                        )
                    }
                    .accessibilityIdentifier("settings.rotateReceiveAddressToggle")
                    .onChange(of: rotateReceiveAddress) {
                        walletManager.reconcileReceiveAddress()
                    }
                } header: {
                    Text("Privacy & Security")
                } footer: {
                    Text("After a payment arrives, Receive shows a new address. Old ones keep working.")
                }

                // Display Section
                Section {
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
                        LanguageSettingsView(choice: $languageChoice)
                    } label: {
                        HStack {
                            SettingsRow(
                                icon: "globe",
                                title: "Language",
                                color: .blue
                            )
                            Spacer()
                            Text((languageChoice ?? AppLanguageSetting.current).spokenName)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("settings.languageRow")

                    NavigationLink {
                        WidgetSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "square.stack.3d.up.fill",
                            title: "Home Screen Widget",
                            color: .blue
                        )
                    }
                } header: {
                    Text("Display")
                }

                // Currency Section
                Section {
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

                    Toggle(isOn: $priceService.showFiatFirst) {
                        SettingsRow(
                            icon: "banknote",
                            title: "Show \(priceService.selectedCurrency.uppercased()) First",
                            color: .green
                        )
                    }
                    .accessibilityIdentifier("settings.fiatModeToggle")

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
                } header: {
                    Text("Currency")
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
                                color: .brand
                            )
                            Spacer()
                            Text(syncStatusText)
                                .foregroundColor(.secondary)
                                // Keeps its width so the title wraps
                                // instead: squeezed, "Синхронизировано"
                                // broke with a hyphen.
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Sync Settings, status \(syncStatusText)")
                    }
                    .accessibilityIdentifier("settings.syncRow")
                }

                // Troubleshooting
                Section("Troubleshooting") {
                    Button {
                        showDiagnosticShare = true
                    } label: {
                        SettingsRow(
                            icon: "doc.text.magnifyingglass",
                            title: "Share Diagnostic Log",
                            color: .purple
                        )
                    }
                    .sheet(isPresented: $showDiagnosticShare) {
                        // Prefer a .txt attachment; fall back to inline text
                        // if the temp file can't be written.
                        let items: [Any] = DiagnosticLog.shared.exportFile().map { [$0] }
                            ?? [DiagnosticLog.shared.export()]
                        ShareSheet(items: items)
                    }
                }

                // About Section
                Section("About") {
                    HStack {
                        SettingsRow(
                            icon: "info.circle",
                            title: "Version",
                            color: .gray
                        )
                        Spacer()
                        Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"), build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")

                    Link(destination: URL(string: "https://monero.one")!) {
                        SettingsRow(
                            icon: "globe",
                            title: "Website",
                            color: .brand
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
                                        colors: [.pink, .brand, .yellow],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 28, height: 28)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(6)

                            Text("Donate XMR")
                                .foregroundColor(.brand)
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
                            color: .brand
                        )
                    }
                    .accessibilityHint("Clears all sync progress and re-syncs from the beginning")

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRow(
                            icon: "trash",
                            title: "Remove All Wallets from Device",
                            color: .red
                        )
                    }
                    .accessibilityHint("Removes every wallet from this device. Recovery with seed phrase is still possible.")
                }
            }
            .navigationTitle("Settings")
            .alert("Reset Sync Data?", isPresented: $showResetSyncConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    walletManager.resetSyncData()
                }
            } message: {
                resetSyncMessage
            }
            .alert("Remove All Wallets from Device?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Remove All", role: .destructive) {
                    walletManager.deleteAllWallets()
                }
            } message: {
                Text("You can restore them only with their seed phrases or keys.")
            }
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: LocalizedStringResource
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
        .accessibilityLabel(Text(title))
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
