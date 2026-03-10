import SwiftUI
import CoreLocation
import MoneroKit

struct SyncSettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject var syncManager = TrustedLocationSyncManager.shared
    @ObservedObject var trustedLocationsManager = TrustedLocationsManager.shared

    @State private var showingRestoreHeightSheet = false
    @State private var showingBackgroundExplanation = false

    private var trustedLocationsCount: String {
        let count = trustedLocationsManager.trustedLocations.count
        if count == 0 {
            return "None"
        } else if count == 1 {
            return "1 location"
        } else {
            return "\(count) locations"
        }
    }

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

            // Node Settings
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

            // Trusted Locations
            Section {
                Toggle(isOn: Binding(
                    get: { syncManager.isEnabled },
                    set: { syncManager.setEnabled($0) }
                )) {
                    Label {
                        Text("Trusted Locations")
                    } icon: {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.green)
                    }
                }
                .tint(.green)

                if syncManager.isEnabled {
                    // Only show permission status when there's a problem
                    if syncManager.authorizationStatus != .authorizedAlways || syncManager.needsPreciseLocation {
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

                        VStack(alignment: .leading, spacing: 12) {
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

                    NavigationLink {
                        TrustedLocationsView()
                    } label: {
                        Label {
                            Text("Manage Locations")
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundColor(.orange)
                        }
                    }
                }
            } header: {
                Text("Trusted Locations")
            }
        }
        .navigationTitle("Sync Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRestoreHeightSheet) {
            RestoreHeightSheet()
        }
        .sheet(isPresented: $showingBackgroundExplanation) {
            TrustedLocationsExplanationView()
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
        if syncManager.authorizationStatus == .authorizedAlways && syncManager.needsPreciseLocation {
            return "Needs Precise Location"
        }
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
        if syncManager.authorizationStatus == .authorizedAlways && syncManager.needsPreciseLocation {
            return .orange
        }
        switch syncManager.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }

    private var permissionWarningText: String {
        if syncManager.authorizationStatus == .authorizedAlways && syncManager.needsPreciseLocation {
            return "Trusted Locations requires Precise Location to accurately determine if you're inside a trusted zone. Go to Settings > Location and enable \"Precise Location\"."
        }
        switch syncManager.authorizationStatus {
        case .authorizedWhenInUse:
            return "Trusted Locations requires \"Always\" location access. Go to Settings > Location and select \"Always\" to enable trusted zone monitoring."
        case .denied:
            return "Location access was denied. Go to Settings > Location and enable location access, then select \"Always\"."
        case .restricted:
            return "Location access is restricted on this device. Check your device settings or parental controls."
        case .notDetermined:
            return "Location permission hasn't been granted yet. Go to Settings > Location and select \"Always\"."
        default:
            return "Please enable \"Always\" location access in Settings to use Trusted Locations."
        }
    }

    // MARK: - Actions

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

    // Monero mainnet genesis: approximately April 2014
    private static let genesisDate = Date(timeIntervalSince1970: 1397818193)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker(
                        "Wallet Birthday",
                        selection: $selectedDate,
                        in: Self.genesisDate...Date(),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    HStack {
                        Text("Current Block Height")
                        Spacer()
                        Text(formatHeight(currentHeight))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Restore From Block")
                        Spacer()
                        Text(formatHeight(estimatedHeight))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Blocks to Scan")
                        Spacer()
                        Text(formatHeight(blocksToScan))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    Text("Set to when you created your wallet to skip older blocks. Monero produces ~1 block every 2 minutes.")
                }
            }
            .safeAreaInset(edge: .bottom) {
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
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpdating)
                .padding()
                .background(.bar)
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
            .alert("Update Restore Height?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Update") {
                    updateRestoreHeight()
                }
            } message: {
                Text("This will restart scanning from block \(formatHeight(estimatedHeight)). Any transactions before this won't be found.")
            }
            .onAppear {
                // Initialize date picker to current restore height's estimated date
                if let date = estimatedDate(for: currentRestoreHeight) {
                    selectedDate = date
                }
            }
        }
    }

    /// Current wallet restore height setting
    private var currentRestoreHeight: UInt64 {
        walletManager.restoreHeight
    }

    /// Current blockchain height (from wallet or estimated from today's date)
    private var currentHeight: UInt64 {
        let daemonHeight = walletManager.daemonHeight
        if daemonHeight > 0 {
            return daemonHeight
        }
        // Fallback: estimate from today's date
        return UInt64(max(0, RestoreHeight.getHeight(date: Date())))
    }

    /// Estimate block height from date using MoneroKit's RestoreHeight utility
    private var estimatedHeight: UInt64 {
        UInt64(max(0, RestoreHeight.getHeight(date: selectedDate)))
    }

    /// Number of blocks that will need to be scanned
    private var blocksToScan: UInt64 {
        if currentHeight > estimatedHeight {
            return currentHeight - estimatedHeight
        }
        return 0
    }

    private func formatHeight(_ height: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: height)) ?? "\(height)"
    }

    /// Estimate date from block height using RestoreHeight lookup table (binary search)
    private func estimatedDate(for height: UInt64) -> Date? {
        guard height > 0 else { return nil }

        // Binary search: find date where RestoreHeight.getHeight(date) is closest to height
        var low = Self.genesisDate
        var high = Date()

        // 20 iterations gives sub-day precision
        for _ in 0..<20 {
            let mid = Date(timeIntervalSince1970: (low.timeIntervalSince1970 + high.timeIntervalSince1970) / 2)
            let midHeight = UInt64(max(0, RestoreHeight.getHeight(date: mid)))

            if midHeight < height {
                low = mid
            } else {
                high = mid
            }
        }

        return low
    }

    private func updateRestoreHeight() {
        isUpdating = true
        let newHeight = estimatedHeight

        // Save to UserDefaults (network-specific)
        let networkPrefix = walletManager.isTestnet ? "testnet_" : "mainnet_"
        UserDefaults.standard.set(Int(newHeight), forKey: "\(networkPrefix)restoreHeight")

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
