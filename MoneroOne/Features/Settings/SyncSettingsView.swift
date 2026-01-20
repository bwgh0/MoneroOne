import SwiftUI
import CoreLocation

struct SyncSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject var syncManager = BackgroundSyncManager.shared
    @AppStorage("syncMode") private var syncMode: String = SyncMode.lite.rawValue

    @State private var showingModeConfirmation = false
    @State private var pendingMode: SyncMode?
    @State private var showingRestoreHeightSheet = false
    @State private var showingBackgroundExplanation = false

    var body: some View {
        List {
            // Current Status
            Section {
                HStack {
                    Label {
                        Text("Status")
                    } icon: {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                    }
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }

                if case .syncing(let progress, let remaining) = walletManager.syncState {
                    VStack(spacing: 8) {
                        ProgressView(value: progress / 100)
                            .tint(.orange)
                        HStack {
                            Text("\(Int(progress))% complete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if let remaining = remaining {
                                Text("\(formatBlockCount(remaining)) blocks remaining")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Sync Status")
            }

            // Sync Mode Selection
            Section {
                // Lite Mode - Coming Soon (disabled)
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                        .foregroundColor(.gray.opacity(0.4))
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Lite Mode")
                                .font(.body)
                                .foregroundColor(.gray)

                            Text("Coming Soon")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }

                        Text("Fast sync using Light Wallet Server. Your view key is shared with the server.")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.6))
                    }

                    Spacer()
                }
                .listRowBackground(Color(.systemGray6))

                // Privacy Mode - selectable
                Button {
                    selectMode(.privacy)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Privacy Mode")
                                    .font(.body)
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
                        }

                        Spacer()

                        if syncMode == SyncMode.privacy.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundColor(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Sync Mode")
            } footer: {
                Text("Privacy Mode syncs directly with a remote node. Your keys never leave your device.")
            }

            // Restore Height
            Section {
                Button {
                    showingRestoreHeightSheet = true
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore Height")
                                    .foregroundColor(.primary)
                                Text("Adjust where scanning starts")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Scan Range")
            } footer: {
                Text("Set this to when you created your wallet to skip scanning older blocks. Useful if sync is taking too long.")
            }

            // Background Sync
            Section {
                Toggle(isOn: Binding(
                    get: { syncManager.isEnabled },
                    set: { syncManager.setEnabled($0) }
                )) {
                    Label {
                        Text("Background Sync")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                    }
                }
                .tint(.orange)

                // Always show permission status
                HStack {
                    Text("Location Permission")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(permissionColor)
                            .frame(width: 8, height: 8)
                        Text(permissionStatus)
                            .foregroundColor(permissionColor)
                    }
                }

                // Show warning and action button if not authorized always
                if syncManager.authorizationStatus != .authorizedAlways {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Action Required")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }

                        Text(permissionWarningText)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            openSettings()
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open Settings")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    showingBackgroundExplanation = true
                } label: {
                    Label("How does this work?", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Background")
            } footer: {
                Text("Keeps wallet synced when app is in background. Uses location permission as a workaround - your location is never stored or transmitted.")
            }

            // Node Settings (for privacy mode)
            if syncMode == SyncMode.privacy.rawValue {
                Section {
                    NavigationLink {
                        NodeSettingsView()
                    } label: {
                        Label {
                            Text("Remote Node")
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundColor(.purple)
                        }
                    }
                } header: {
                    Text("Connection")
                }
            }
        }
        .navigationTitle("Sync Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Switch Sync Mode?", isPresented: $showingModeConfirmation) {
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
        .sheet(isPresented: $showingRestoreHeightSheet) {
            RestoreHeightSheet()
        }
        .sheet(isPresented: $showingBackgroundExplanation) {
            BackgroundSyncExplanationView()
        }
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        switch walletManager.syncState {
        case .synced: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .connecting: return "wifi"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "moon.fill"
        }
    }

    private var statusColor: Color {
        switch walletManager.syncState {
        case .synced: return .green
        case .syncing: return .orange
        case .connecting: return .yellow
        case .error: return .red
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch walletManager.syncState {
        case .synced: return "Synced"
        case .syncing(let progress, _): return "Scanning \(Int(progress))%"
        case .connecting: return "Connecting..."
        case .error(let msg): return msg
        case .idle: return "Idle"
        }
    }

    private var permissionStatus: String {
        switch syncManager.authorizationStatus {
        case .authorizedAlways: return "Enabled"
        case .authorizedWhenInUse: return "Needs Always Permission"
        case .denied: return "Permission Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Configured"
        @unknown default: return "Unknown"
        }
    }

    private var permissionColor: Color {
        switch syncManager.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }

    private var permissionWarningText: String {
        switch syncManager.authorizationStatus {
        case .authorizedWhenInUse:
            return "Background sync requires \"Always\" location access. Go to Settings > Location and select \"Always\" to enable background syncing."
        case .denied:
            return "Location access was denied. Go to Settings > Location and enable location access, then select \"Always\"."
        case .restricted:
            return "Location access is restricted on this device. Check your device settings or parental controls."
        case .notDetermined:
            return "Location permission hasn't been granted yet. Go to Settings > Location and select \"Always\"."
        default:
            return "Please enable \"Always\" location access in Settings to use background sync."
        }
    }

    // MARK: - Actions

    private func selectMode(_ mode: SyncMode) {
        guard mode.rawValue != syncMode else { return }

        if walletManager.isUnlocked {
            pendingMode = mode
            showingModeConfirmation = true
        } else {
            applyMode(mode)
        }
    }

    private func applyMode(_ mode: SyncMode) {
        syncMode = mode.rawValue
        if walletManager.isUnlocked {
            walletManager.switchSyncMode(to: mode)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func formatBlockCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Restore Height Sheet

struct RestoreHeightSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedDate = Date()
    @State private var isUpdating = false
    @State private var showConfirmation = false
    @State private var chainHeight: UInt64 = 0
    @State private var isLoadingHeight = true

    // Monero mainnet genesis: approximately April 2014
    // For testnet, we'll cap the calculated height to chain height
    private static let genesisDate = Date(timeIntervalSince1970: 1397818193)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker(
                        "Wallet Creation Date",
                        selection: $selectedDate,
                        in: Self.genesisDate...Date(),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                } header: {
                    Text("When did you create this wallet?")
                } footer: {
                    Text("Scanning will start from this date. Set this to when you first created the wallet to skip older blocks.")
                }

                Section {
                    HStack {
                        Text("Estimated Block Height")
                        Spacer()
                        if isLoadingHeight {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text(formatHeight(effectiveHeight))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if !isLoadingHeight && chainHeight > 0 {
                        HStack {
                            Text("Current Chain Height")
                            Spacer()
                            Text(formatHeight(chainHeight))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    if walletManager.isTestnet {
                        Text("Testnet block heights differ from mainnet. Using actual chain height when needed.")
                    } else {
                        Text("Monero produces ~1 block every 2 minutes.")
                    }
                }

                Section {
                    Button {
                        showConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isUpdating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Update Restore Height")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isUpdating || isLoadingHeight)
                } footer: {
                    Text("This will re-register your wallet with the server and restart scanning from the selected date.")
                }
            }
            .navigationTitle("Restore Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await fetchChainHeight()
            }
            .alert("Update Restore Height?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Update") {
                    updateRestoreHeight()
                }
            } message: {
                Text("This will restart scanning from block \(formatHeight(effectiveHeight)). Any transactions before this won't be found.")
            }
        }
    }

    /// The effective height to use - calculated relative to current chain height
    private var effectiveHeight: UInt64 {
        guard chainHeight > 0 else { return 0 }

        // Calculate how many seconds ago the selected date is
        let secondsAgo = Date().timeIntervalSince(selectedDate)
        guard secondsAgo > 0 else {
            // Selected date is today or future - use current chain height
            return chainHeight
        }

        // Convert to blocks (~2 min per block = 120 seconds)
        let blocksAgo = UInt64(secondsAgo / 120)

        // Subtract from current chain height
        if blocksAgo >= chainHeight {
            return 0 // Would go negative, start from beginning
        }
        return chainHeight - blocksAgo
    }

    private func formatHeight(_ height: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: height)) ?? "\(height)"
    }

    private func fetchChainHeight() async {
        let client = LiteWalletServerClient(isTestnet: walletManager.isTestnet)
        do {
            let response = try await client.getBlockchainHeight()
            await MainActor.run {
                chainHeight = response.height
                isLoadingHeight = false
            }
        } catch {
            await MainActor.run {
                isLoadingHeight = false
            }
        }
    }

    private func updateRestoreHeight() {
        isUpdating = true
        let newHeight = effectiveHeight

        // Save to UserDefaults
        UserDefaults.standard.set(Int(newHeight), forKey: "restoreHeight")

        // Re-register with server if in lite mode
        Task {
            // Small delay to show loading state
            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run {
                // Reset sync to apply new height
                walletManager.resetSyncData()
                isUpdating = false
                dismiss()
            }
        }
    }
}

#Preview {
    NavigationStack {
        SyncSettingsView()
            .environmentObject(WalletManager())
    }
}
