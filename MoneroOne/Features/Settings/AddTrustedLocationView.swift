import SwiftUI
import MapKit
import CoreLocation

struct AddTrustedLocationView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var locationsManager = TrustedLocationsManager.shared

    // Editing mode
    var editingLocation: TrustedLocation?
    var isEditing: Bool { editingLocation != nil }

    // Form state
    @State private var name: String = ""
    @State private var selectedRadius: Double = 500
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var region: MKCoordinateRegion = .init(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    // Location manager for current location
    @StateObject private var locationFetcher = CurrentLocationFetcher()

    // Search
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    // UI state
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Search address", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit {
                            performSearch()
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))

                // Search results overlay
                if !searchResults.isEmpty {
                    List(searchResults, id: \.self) { item in
                        Button {
                            selectSearchResult(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Unknown")
                                    .foregroundColor(.primary)
                                if let address = item.placemark.title {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 200)
                }

                // Map
                ZStack {
                    Map(coordinateRegion: $region, interactionModes: .all, annotationItems: annotationItems) { item in
                        MapAnnotation(coordinate: item.coordinate) {
                            ZStack {
                                // Radius circle
                                Circle()
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: radiusInPoints, height: radiusInPoints)

                                Circle()
                                    .stroke(Color.orange, lineWidth: 2)
                                    .frame(width: radiusInPoints, height: radiusInPoints)

                                // Center pin
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .gesture(
                        LongPressGesture(minimumDuration: 0.3)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onEnded { value in
                                // Handle long press to place pin
                                // Note: This is a simplified approach - for production,
                                // use a tap gesture recognizer via UIViewRepresentable
                            }
                    )

                    // Center crosshair for tap-to-place
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                useCurrentLocation()
                            } label: {
                                Image(systemName: "location.fill")
                                    .font(.title2)
                                    .padding()
                                    .background(Color(.systemBackground))
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }
                            .padding()
                        }
                    }

                    // Tap instruction
                    if coordinate == nil {
                        VStack {
                            Text("Tap the map to place a pin")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemBackground).opacity(0.9))
                                .cornerRadius(8)
                                .shadow(radius: 2)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .onTapGesture { location in
                    // Convert tap to coordinate
                    // Note: This requires calculating based on region
                    // For a proper implementation, use MKMapView via UIViewRepresentable
                    placeMarkerAtCenter()
                }

                // Form
                VStack(spacing: 16) {
                    // Name field
                    HStack {
                        Image(systemName: "tag")
                            .foregroundColor(.secondary)
                        TextField("Location name (e.g., Home)", text: $name)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                    // Radius picker
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "circle.dashed")
                                .foregroundColor(.secondary)
                            Text("Radius: \(radiusText)")
                            Spacer()
                        }

                        Slider(value: $selectedRadius, in: 100...2000, step: 100) {
                            Text("Radius")
                        }
                        .tint(.orange)

                        // Preset buttons
                        HStack(spacing: 8) {
                            ForEach(TrustedLocation.RadiusPreset.allCases, id: \.self) { preset in
                                Button {
                                    selectedRadius = preset.rawValue
                                } label: {
                                    Text(preset.displayName)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedRadius == preset.rawValue ? Color.orange : Color(.tertiarySystemBackground))
                                        .foregroundColor(selectedRadius == preset.rawValue ? .white : .primary)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                    // Save button
                    Button {
                        saveLocation()
                    } label: {
                        Text(isEditing ? "Update Location" : "Add Location")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canSave ? Color.orange : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!canSave)

                    // Delete button (edit mode only)
                    if isEditing {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Text("Delete Location")
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(isEditing ? "Edit Location" : "Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Location?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let location = editingLocation {
                        locationsManager.removeLocation(location)
                    }
                    dismiss()
                }
            } message: {
                Text("This location will be removed from your trusted zones.")
            }
            .onAppear {
                setupInitialState()
            }
        }
    }

    // MARK: - Computed Properties

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && coordinate != nil
    }

    private var radiusText: String {
        if selectedRadius >= 1000 {
            return String(format: "%.1f km", selectedRadius / 1000)
        } else {
            return "\(Int(selectedRadius))m"
        }
    }

    private var annotationItems: [MapPin] {
        if let coord = coordinate {
            return [MapPin(coordinate: coord)]
        }
        return []
    }

    private var radiusInPoints: CGFloat {
        // Approximate conversion from meters to points based on zoom level
        let metersPerDegree = 111_000.0  // roughly
        let degreesPerMeter = 1.0 / metersPerDegree
        let radiusDegrees = selectedRadius * degreesPerMeter
        let spanDegrees = region.span.latitudeDelta

        // Map view is roughly 300-400 points wide
        let mapWidthPoints: CGFloat = 350
        let radiusPoints = CGFloat(radiusDegrees / spanDegrees) * mapWidthPoints

        return min(max(radiusPoints, 40), 300)  // Clamp between 40 and 300 points
    }

    // MARK: - Actions

    private func setupInitialState() {
        if let location = editingLocation {
            // Editing existing location
            name = location.name
            selectedRadius = location.radius
            coordinate = location.coordinate
            region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else {
            // New location - try to get current location
            useCurrentLocation()
        }
    }

    private func useCurrentLocation() {
        locationFetcher.requestLocation { location in
            if let location = location {
                coordinate = location.coordinate
                region = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            }
        }
    }

    private func placeMarkerAtCenter() {
        coordinate = region.center
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }

        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        request.region = region

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            isSearching = false
            if let response = response {
                searchResults = response.mapItems
            }
        }
    }

    private func selectSearchResult(_ item: MKMapItem) {
        coordinate = item.placemark.coordinate
        region = MKCoordinateRegion(
            center: item.placemark.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        searchResults = []
        searchText = ""

        // Auto-fill name if empty
        if name.isEmpty, let itemName = item.name {
            name = itemName
        }
    }

    private func saveLocation() {
        guard let coord = coordinate else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existing = editingLocation {
            // Update existing
            var updated = existing
            updated.name = trimmedName
            updated.coordinate = coord
            updated.radius = selectedRadius
            locationsManager.updateLocation(updated)
        } else {
            // Create new
            let location = TrustedLocation(
                name: trimmedName,
                coordinate: coord,
                radius: selectedRadius
            )
            locationsManager.addLocation(location)
        }

        dismiss()
    }
}

// MARK: - Helper Types

struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Current Location Fetcher

class CurrentLocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    private var locationManager: CLLocationManager?
    private var completion: ((CLLocation?) -> Void)?

    func requestLocation(completion: @escaping (CLLocation?) -> Void) {
        self.completion = completion

        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyBest
        locationManager?.requestWhenInUseAuthorization()
        locationManager?.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        completion?(locations.last)
        completion = nil
        locationManager = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        completion?(nil)
        completion = nil
        locationManager = nil
    }
}

#Preview {
    AddTrustedLocationView()
}
