import SwiftUI
import CoreLocation

struct TrustedLocationsView: View {
    @ObservedObject var locationsManager = TrustedLocationsManager.shared
    @State private var showingAddLocation = false
    @State private var editingLocation: TrustedLocation?

    var body: some View {
        List {
            // Sync Mode Selection
            if locationsManager.hasTrustedLocations {
                Section {
                    Picker("Sync Mode", selection: $locationsManager.syncMode) {
                        ForEach(TrustedLocationMode.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                            }
                            .tag(mode)
                        }
                    }
                } header: {
                    Text("Outside Trusted Zones")
                } footer: {
                    Text(locationsManager.syncMode.description)
                }
            }

            // Current Status
            if locationsManager.hasTrustedLocations {
                Section {
                    HStack {
                        Text("Current Status")
                        Spacer()
                        if locationsManager.isInTrustedZone {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                if let name = locationsManager.currentLocationName {
                                    Text(name)
                                        .foregroundColor(.green)
                                } else {
                                    Text("Trusted")
                                        .foregroundColor(.green)
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                Text("Outside trusted zones")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            }

            // Trusted Locations List
            Section {
                if locationsManager.trustedLocations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "location.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No Trusted Locations")
                            .font(.headline)

                        Text("Add your home, office, or other safe locations where your wallet syncs regularly.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(locationsManager.trustedLocations) { location in
                        TrustedLocationRow(location: location)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingLocation = location
                            }
                    }
                    .onDelete(perform: deleteLocations)
                }

                Button {
                    showingAddLocation = true
                } label: {
                    Label("Add Trusted Location", systemImage: "plus.circle.fill")
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Trusted Locations")
            } footer: {
                if locationsManager.trustedLocations.count >= 15 {
                    Text("iOS limits apps to 20 monitored regions. You have \(locationsManager.trustedLocations.count) trusted locations.")
                        .foregroundColor(.orange)
                }
            }

        }
        .navigationTitle("Trusted Locations")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddLocation) {
            AddTrustedLocationView()
        }
        .sheet(item: $editingLocation) { location in
            AddTrustedLocationView(editingLocation: location)
        }
    }

    private func deleteLocations(at offsets: IndexSet) {
        for index in offsets {
            let location = locationsManager.trustedLocations[index]
            locationsManager.removeLocation(location)
        }
    }
}

struct TrustedLocationRow: View {
    let location: TrustedLocation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.body)

                Text(radiusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        let lowercaseName = location.name.lowercased()
        if lowercaseName.contains("home") || lowercaseName.contains("house") {
            return "house.fill"
        } else if lowercaseName.contains("work") || lowercaseName.contains("office") {
            return "building.2.fill"
        } else if lowercaseName.contains("gym") || lowercaseName.contains("fitness") {
            return "dumbbell.fill"
        } else if lowercaseName.contains("school") || lowercaseName.contains("university") || lowercaseName.contains("college") {
            return "graduationcap.fill"
        } else if lowercaseName.contains("coffee") || lowercaseName.contains("cafe") {
            return "cup.and.saucer.fill"
        } else {
            return "mappin.circle.fill"
        }
    }

    private var radiusDescription: String {
        if location.radius >= 1000 {
            return String(format: "%.1f km radius", location.radius / 1000)
        } else {
            return "\(Int(location.radius))m radius"
        }
    }
}

#Preview {
    NavigationStack {
        TrustedLocationsView()
    }
}
