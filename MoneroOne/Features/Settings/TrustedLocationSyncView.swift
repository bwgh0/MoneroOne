import SwiftUI
import CoreLocation

struct TrustedLocationSyncView: View {
    @ObservedObject var syncManager = TrustedLocationSyncManager.shared
    @State private var showingExplanation = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { syncManager.isEnabled },
                    set: { syncManager.setEnabled($0) }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.green)
                        Text("Trusted Locations")
                    }
                }
                .tint(.green)
            } footer: {
                Text("Define security zones where your wallet stays updated. Requires \"Always\" location permission.")
            }

            // Always show permission status section
            Section("Location Permission") {
                HStack {
                    Text("Current Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(permissionColor)
                            .frame(width: 8, height: 8)
                        Text(permissionStatus)
                            .foregroundColor(permissionColor)
                    }
                }

                // Show warning if not "Always" permission
                if syncManager.authorizationStatus != .authorizedAlways || syncManager.needsPreciseLocation {
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
            }

            if syncManager.isEnabled {
                Section("Sync Status") {
                    if syncManager.isSyncing {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Syncing...")
                                    .foregroundColor(.orange)
                            }
                        }
                    } else if let lastSync = syncManager.lastSyncTime {
                        HStack {
                            Text("Last Sync")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text("Ready")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    showingExplanation = true
                } label: {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("How does this work?")
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Trusted Locations")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingExplanation) {
            TrustedLocationsExplanationView()
        }
    }

    private var permissionStatus: String {
        if syncManager.authorizationStatus == .authorizedAlways && syncManager.needsPreciseLocation {
            return "Needs Precise"
        }
        switch syncManager.authorizationStatus {
        case .authorizedAlways:
            return "Granted"
        case .authorizedWhenInUse:
            return "Needs Always"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Set"
        @unknown default:
            return "Unknown"
        }
    }

    private var permissionColor: Color {
        if syncManager.authorizationStatus == .authorizedAlways && syncManager.needsPreciseLocation {
            return .orange
        }
        switch syncManager.authorizationStatus {
        case .authorizedAlways:
            return .green
        case .authorizedWhenInUse:
            return .orange
        default:
            return .red
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

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct TrustedLocationsExplanationView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Trusted Locations", systemImage: "shield.checkered")
                            .font(.headline)
                            .foregroundColor(.green)

                        Text("Trusted Locations defines security zones around places you choose. Your wallet stays updated when you're in these safe areas.")

                        Text("Add your home, office, or other safe locations. If your wallet detects activity outside these zones, you'll be notified.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("How It Works", systemImage: "gearshape.2")
                            .font(.headline)

                        Text("When you're inside a trusted zone, your wallet checks for new transactions at optimal times.")

                        Text("This protects you from wallet activity on untrusted networks like public Wi-Fi or unknown locations.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Privacy", systemImage: "lock.shield")
                            .font(.headline)
                            .foregroundColor(.blue)

                        Text("Your location data stays on your device. It's only used to check if you're in a trusted zone - never stored, logged, or transmitted anywhere.")

                        Text("Monero One is open source. You can verify exactly how location is used in the code.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Battery Impact", systemImage: "battery.75")
                            .font(.headline)
                            .foregroundColor(.orange)

                        Text("We use low-power location monitoring to minimize battery drain. You may notice slightly higher battery usage when enabled.")
                    }
                }
                .padding()
            }
            .navigationTitle("Trusted Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TrustedLocationSyncView()
    }
}
