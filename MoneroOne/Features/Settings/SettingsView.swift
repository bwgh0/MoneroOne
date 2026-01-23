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
    @AppStorage("syncMode") private var syncMode: String = SyncMode.privacy.rawValue
    @State private var showBackup = false
    @State private var showSecurity = false
    @State private var showSyncMode = false
    @State private var showDeleteConfirmation = false
    @State private var showResetSyncConfirmation = false
    @State private var showNetworkChangeAlert = false
    @AppStorage("isTestnet") private var isTestnet = false

    private var currentSyncMode: String {
        SyncMode(rawValue: syncMode)?.rawValue ?? "Lite Mode"
    }

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

                    NavigationLink {
                        SecurityView()
                    } label: {
                        SettingsRow(
                            icon: "lock.shield",
                            title: "Security",
                            color: .blue
                        )
                    }
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
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://monero.one")!) {
                        SettingsRow(
                            icon: "globe",
                            title: "Website",
                            color: .orange
                        )
                    }
                }

                // Developer Section
                Section {
                    Toggle(isOn: Binding(
                        get: { isTestnet },
                        set: { newValue in
                            if newValue != isTestnet {
                                showNetworkChangeAlert = true
                            }
                        }
                    )) {
                        HStack {
                            SettingsRow(
                                icon: "flask",
                                title: "Testnet Mode",
                                color: .cyan
                            )
                            if isTestnet {
                                Text("Active")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.cyan)
                                    .cornerRadius(4)
                            }
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Testnet uses test XMR with no real value. Note: Testnet nodes are often unreliable.")
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

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRow(
                            icon: "trash",
                            title: "Remove Wallet from Device",
                            color: .red
                        )
                    }
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
            .alert(isTestnet ? "Switch to Mainnet?" : "Switch to Testnet?", isPresented: $showNetworkChangeAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Switch Network") {
                    isTestnet.toggle()

                    // Auto-select first node for the new network
                    if isTestnet {
                        // Switched TO testnet, select first testnet node
                        if let firstTestnetNode = MoneroWallet.testnetNodes.first {
                            UserDefaults.standard.set(firstTestnetNode.url, forKey: "selectedTestnetNodeURL")
                        }
                    } else {
                        // Switched TO mainnet, select first mainnet node
                        if let firstMainnetNode = MoneroWallet.publicNodes.first {
                            UserDefaults.standard.set(firstMainnetNode.url, forKey: "selectedNodeURL")
                        }
                    }

                    walletManager.switchNetwork()
                }
            } message: {
                if isTestnet {
                    Text("Switching to mainnet. Your sync progress for each network is saved separately.")
                } else {
                    Text("Switching to testnet. Testnet XMR has no real value. Your mainnet sync progress will be preserved.")
                }
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
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
