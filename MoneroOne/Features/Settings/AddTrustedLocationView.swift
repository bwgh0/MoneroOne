import SwiftUI
import MapKit
import CoreLocation

// MARK: - Search Completer

class SearchCompleterDelegate: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    var queryFragment: String {
        get { completer.queryFragment }
        set { completer.queryFragment = newValue }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - Map Subview

struct TrustedLocationMapView: View {
    @Binding var cameraPosition: MapCameraPosition
    @Binding var coordinate: CLLocationCoordinate2D?
    var selectedRadius: Double

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let coord = coordinate {
                    MapCircle(center: coord, radius: selectedRadius)
                        .foregroundStyle(Color.orange.opacity(0.2))
                        .stroke(Color.orange, lineWidth: 2)

                    Annotation("", coordinate: coord) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundColor(.orange)
                    }
                }
            }
            .onTapGesture { position in
                if let coord = proxy.convert(position, from: .local) {
                    coordinate = coord
                }
            }
        }
    }
}

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
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    ))

    // Location manager for current location
    @StateObject private var locationFetcher = CurrentLocationFetcher()

    // Search
    @State private var searchText = ""
    @StateObject private var searchCompleter = SearchCompleterDelegate()

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

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchCompleter.results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.queryFragment = newValue
                }

                // Map area with search results overlaid
                ZStack(alignment: .top) {
                    ZStack {
                        TrustedLocationMapView(
                            cameraPosition: $cameraPosition,
                            coordinate: $coordinate,
                            selectedRadius: selectedRadius
                        )

                        // Current location button
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

                    // Search results dropdown (overlays map)
                    if !searchCompleter.results.isEmpty {
                        List(searchCompleter.results, id: \.self) { completion in
                            Button {
                                resolveCompletion(completion)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(completion.title)
                                        .foregroundColor(.primary)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .frame(maxHeight: 200)
                        .background(Color(.systemBackground))
                        .shadow(radius: 4)
                    }
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

    // MARK: - Actions

    private func setupInitialState() {
        if let location = editingLocation {
            name = location.name
            selectedRadius = location.radius
            coordinate = location.coordinate
            cameraPosition = .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        } else {
            useCurrentLocation()
        }
    }

    private func useCurrentLocation() {
        locationFetcher.requestLocation { location in
            if let location = location {
                coordinate = location.coordinate
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))
                }
            }
        }
    }

    private func resolveCompletion(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            guard let item = response?.mapItems.first else { return }
            coordinate = item.placemark.coordinate
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
            searchCompleter.results = []
            searchText = ""

            if name.isEmpty, let itemName = item.name {
                name = itemName
            }
        }
    }

    private func saveLocation() {
        guard let coord = coordinate else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existing = editingLocation {
            var updated = existing
            updated.name = trimmedName
            updated.coordinate = coord
            updated.radius = selectedRadius
            locationsManager.updateLocation(updated)
        } else {
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
