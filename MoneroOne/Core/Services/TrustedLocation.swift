import Foundation
import CoreLocation

/// A trusted location defining a security zone for wallet sync
struct TrustedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var coordinate: CLLocationCoordinate2D
    var radius: CLLocationDistance  // in meters

    init(id: UUID = UUID(), name: String, coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 500) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.radius = radius
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, radius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        radius = try container.decode(Double.self, forKey: .radius)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
        try container.encode(radius, forKey: .radius)
    }

    // MARK: - Equatable

    static func == (lhs: TrustedLocation, rhs: TrustedLocation) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.radius == rhs.radius
    }

    // MARK: - Geofencing

    /// Create a CLCircularRegion for geofence monitoring
    var region: CLCircularRegion {
        let region = CLCircularRegion(
            center: coordinate,
            radius: radius,
            identifier: id.uuidString
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }

    /// Check if a location is within this trusted zone
    func contains(_ location: CLLocation) -> Bool {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: center) <= radius
    }
}

// MARK: - Radius Presets

extension TrustedLocation {
    enum RadiusPreset: Double, CaseIterable {
        case small = 200      // 200m - apartment/small property
        case medium = 500     // 500m - house/neighborhood
        case large = 1000     // 1km - campus/complex
        case extraLarge = 2000 // 2km - district

        var displayName: String {
            switch self {
            case .small: return "200m"
            case .medium: return "500m"
            case .large: return "1km"
            case .extraLarge: return "2km"
            }
        }

        var description: String {
            switch self {
            case .small: return "Apartment"
            case .medium: return "Home"
            case .large: return "Campus"
            case .extraLarge: return "District"
            }
        }
    }
}
