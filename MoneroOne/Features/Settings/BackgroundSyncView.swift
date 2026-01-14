import SwiftUI
import CoreLocation

struct BackgroundSyncView: View {
    @ObservedObject var syncManager = BackgroundSyncManager.shared
    @State private var showingExplanation = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { syncManager.isEnabled },
                    set: { syncManager.setEnabled($0) }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                        Text("Background Sync")
                    }
                }
                .tint(.orange)
            } footer: {
                Text("Keeps your wallet synced even when the app is in the background. Requires location permission.")
            }

            if syncManager.isEnabled {
                Section("Status") {
                    HStack {
                        Text("Permission")
                        Spacer()
                        Text(permissionStatus)
                            .foregroundColor(permissionColor)
                    }

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
                    }
                }

                if syncManager.needsAuthorization {
                    Section {
                        Button {
                            openSettings()
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open Settings to Grant Permission")
                            }
                            .foregroundColor(.orange)
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
        .navigationTitle("Background Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingExplanation) {
            BackgroundSyncExplanationView()
        }
    }

    private var permissionStatus: String {
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
        switch syncManager.authorizationStatus {
        case .authorizedAlways:
            return .green
        case .authorizedWhenInUse:
            return .orange
        default:
            return .red
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct BackgroundSyncExplanationView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("How It Works", systemImage: "gearshape.2")
                            .font(.headline)

                        Text("iOS doesn't allow apps to run continuously in the background. However, apps that use location services can stay active.")

                        Text("By enabling background sync, we request location updates which keeps the app alive to sync your wallet.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Privacy", systemImage: "lock.shield")
                            .font(.headline)
                            .foregroundColor(.green)

                        Text("Your location is NEVER stored, transmitted, or used for anything.")

                        Text("This is purely a technical workaround to enable background execution. The app is open source - you can verify this yourself.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Battery Impact", systemImage: "battery.75")
                            .font(.headline)
                            .foregroundColor(.orange)

                        Text("We use low-accuracy location updates to minimize battery drain. You may notice slightly higher battery usage with this enabled.")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.headline)
                            .foregroundColor(.blue)

                        Text("Monero One is fully open source. Review the code at:")

                        Text("github.com/user/MoneroOne")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Background Sync")
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
        BackgroundSyncView()
    }
}
