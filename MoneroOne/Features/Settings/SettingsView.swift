import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showBackup = false
    @State private var showSecurity = false
    @State private var showSyncMode = false
    @State private var showDeleteConfirmation = false

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
                }

                // Sync Section
                Section("Sync") {
                    NavigationLink {
                        BackgroundSyncView()
                    } label: {
                        HStack {
                            SettingsRow(
                                icon: "arrow.triangle.2.circlepath",
                                title: "Background Sync",
                                color: .orange
                            )
                            Spacer()
                            if BackgroundSyncManager.shared.isEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }

                    NavigationLink {
                        NodeSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "server.rack",
                            title: "Remote Node",
                            color: .purple
                        )
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

                    Link(destination: URL(string: "https://getmonero.org")!) {
                        SettingsRow(
                            icon: "globe",
                            title: "Monero Website",
                            color: .orange
                        )
                    }
                }

                // Danger Zone
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRow(
                            icon: "trash",
                            title: "Delete Wallet",
                            color: .red
                        )
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Delete Wallet?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    walletManager.deleteWallet()
                }
            } message: {
                Text("This will remove all wallet data from this device. Make sure you have backed up your seed phrase!")
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
}
