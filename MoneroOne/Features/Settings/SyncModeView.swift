import SwiftUI

enum SyncMode: String, CaseIterable {
    case lite = "Lite Mode"
    case privacy = "Privacy Mode"

    var description: String {
        switch self {
        case .lite:
            return "Fast sync using Light Wallet Server. Your view key is shared with the server."
        case .privacy:
            return "Full privacy sync using remote node. Slower but your keys stay local."
        }
    }

    var icon: String {
        switch self {
        case .lite: return "bolt.fill"
        case .privacy: return "shield.fill"
        }
    }
}

struct SyncModeView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("syncMode") private var syncMode: String = SyncMode.lite.rawValue
    @State private var showingConfirmation = false
    @State private var pendingMode: SyncMode?

    var body: some View {
        List {
            Section {
                // Lite Mode - Coming Soon (disabled, not selectable)
                HStack(spacing: 12) {
                    ZStack {
                        Image(systemName: "bolt.fill")
                            .font(.title2)
                            .foregroundColor(.gray.opacity(0.4))
                            .frame(width: 40)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Lite Mode")
                                .font(.headline)
                                .foregroundColor(.gray)

                            Text("Coming Soon")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(6)
                        }

                        Text("Fast sync using Light Wallet Server. Your view key is shared with the server.")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color(.systemGray6))

                // Privacy Mode - selectable
                Button {
                    selectMode(.privacy)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Privacy Mode")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                if walletManager.currentSyncMode == .privacy {
                                    Text("Active")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }
                            }

                            Text("Full privacy sync using remote node. Slower but your keys stay local.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if syncMode == SyncMode.privacy.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy Mode syncs directly with a remote node. Your keys never leave your device.")

                    if walletManager.isUnlocked {
                        Text("Switching modes will restart your wallet sync.")
                            .foregroundColor(.orange)
                    }
                }
            }

            if walletManager.currentSyncMode == .lite {
                Section("Server Status") {
                    HStack {
                        Text("Light Wallet Server")
                        Spacer()
                        serverStatusBadge
                    }

                    HStack {
                        Text("Network")
                        Spacer()
                        Text(walletManager.isTestnet ? "Testnet" : "Mainnet")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sync Mode")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Switch Sync Mode?", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingMode = nil
            }
            Button("Switch") {
                if let mode = pendingMode {
                    applyMode(mode)
                }
                pendingMode = nil
            }
        } message: {
            if let mode = pendingMode {
                Text("Switch to \(mode.rawValue)? Your wallet will restart syncing.")
            }
        }
    }

    @ViewBuilder
    private var serverStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(serverStatusColor)
                .frame(width: 8, height: 8)
            Text(serverStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var serverStatusColor: Color {
        switch walletManager.syncState {
        case .synced: return .green
        case .syncing: return .orange
        case .connecting: return .yellow
        case .error: return .red
        case .idle: return .gray
        }
    }

    private var serverStatusText: String {
        switch walletManager.syncState {
        case .synced: return "Connected"
        case .syncing: return "Syncing"
        case .connecting: return "Connecting"
        case .error: return "Error"
        case .idle: return "Idle"
        }
    }

    private func selectMode(_ mode: SyncMode) {
        guard mode.rawValue != syncMode else { return }

        if walletManager.isUnlocked {
            // Show confirmation if wallet is active
            pendingMode = mode
            showingConfirmation = true
        } else {
            // Just save preference if wallet not unlocked
            applyMode(mode)
        }
    }

    private func applyMode(_ mode: SyncMode) {
        syncMode = mode.rawValue

        if walletManager.isUnlocked {
            // Trigger mode switch in wallet manager
            walletManager.switchSyncMode(to: mode)
        }
    }
}

#Preview {
    NavigationStack {
        SyncModeView()
            .environmentObject(WalletManager())
    }
}
