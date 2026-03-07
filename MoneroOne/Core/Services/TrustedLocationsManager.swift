import Foundation
import CoreLocation
import UserNotifications
import SwiftUI

/// Sync behavior when outside trusted locations
enum TrustedLocationMode: String, CaseIterable, Identifiable {
    case warnOnly = "warnOnly"
    case blockSync = "blockSync"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .warnOnly: return "Warn Only"
        case .blockSync: return "Block Sync"
        }
    }

    var description: String {
        switch self {
        case .warnOnly: return "Sync everywhere, notify when outside trusted zones"
        case .blockSync: return "Only sync when inside a trusted zone"
        }
    }
}

/// Manages trusted location security zones for wallet sync
/// When trusted locations are configured, the user is warned when syncing outside them
/// Syncing can optionally be blocked (configurable)
@MainActor
class TrustedLocationsManager: NSObject, ObservableObject {
    static let shared = TrustedLocationsManager()

    // MARK: - Published State

    @Published private(set) var trustedLocations: [TrustedLocation] = []
    @Published private(set) var currentLocationName: String?  // Name of current trusted zone, nil if outside all
    @Published private(set) var isInTrustedZone: Bool = true  // True if no locations configured OR inside a zone
    @Published private(set) var lastKnownLocation: CLLocation?

    /// User preference for sync behavior outside trusted zones
    @Published var syncMode: TrustedLocationMode {
        didSet { UserDefaults.standard.set(syncMode.rawValue, forKey: "trustedLocationMode") }
    }

    // MARK: - Private

    private let storageKey = "trustedLocations"
    private var locationManager: CLLocationManager?
    private var hasWarnedOutsideTrustedZone = false
    private var lastWarningTime: Date?
    private let warningCooldown: TimeInterval = 3600  // Don't warn more than once per hour

    // MARK: - Init

    private override init() {
        let raw = UserDefaults.standard.string(forKey: "trustedLocationMode") ?? TrustedLocationMode.warnOnly.rawValue
        self.syncMode = TrustedLocationMode(rawValue: raw) ?? .warnOnly
        super.init()
        loadLocations()
    }

    // MARK: - Location Management

    /// Add a new trusted location
    func addLocation(_ location: TrustedLocation) {
        trustedLocations.append(location)
        saveLocations()
        startMonitoringRegion(location)
        reevaluateZoneStatus()
    }

    /// Remove a trusted location
    func removeLocation(_ location: TrustedLocation) {
        trustedLocations.removeAll { $0.id == location.id }
        saveLocations()
        stopMonitoringRegion(location)
        reevaluateZoneStatus()
    }

    /// Update an existing trusted location
    func updateLocation(_ location: TrustedLocation) {
        if let index = trustedLocations.firstIndex(where: { $0.id == location.id }) {
            // Stop monitoring old region
            stopMonitoringRegion(trustedLocations[index])
            // Update
            trustedLocations[index] = location
            saveLocations()
            // Start monitoring new region
            startMonitoringRegion(location)
            reevaluateZoneStatus()
        }
    }

    /// Check if any trusted locations are configured
    var hasTrustedLocations: Bool {
        !trustedLocations.isEmpty
    }

    // MARK: - Geofence Monitoring

    /// Start monitoring all trusted location geofences
    func startMonitoring() {
        guard !trustedLocations.isEmpty else { return }

        if locationManager == nil {
            locationManager = CLLocationManager()
            locationManager?.delegate = self
        }

        // Monitor each trusted location
        for location in trustedLocations {
            startMonitoringRegion(location)
        }

        // Get initial location to determine current zone
        locationManager?.requestLocation()
    }

    /// Stop monitoring all geofences
    func stopMonitoring() {
        guard let manager = locationManager else { return }

        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    private func startMonitoringRegion(_ location: TrustedLocation) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        locationManager?.startMonitoring(for: location.region)
    }

    private func stopMonitoringRegion(_ location: TrustedLocation) {
        locationManager?.stopMonitoring(for: location.region)
    }

    // MARK: - Zone Detection

    /// Re-evaluate zone status after locations or settings change
    private func reevaluateZoneStatus() {
        if let location = lastKnownLocation {
            updateZoneStatus(for: location)
        } else if trustedLocations.isEmpty {
            currentLocationName = nil
            isInTrustedZone = true
        } else {
            // Have locations but no position yet — assume outside
            currentLocationName = nil
            isInTrustedZone = false
        }
    }

    /// Update current zone status based on a location
    func updateZoneStatus(for location: CLLocation) {
        lastKnownLocation = location

        // Find which trusted zone we're in (if any)
        let matchingZone = trustedLocations.first { $0.contains(location) }

        if let zone = matchingZone {
            currentLocationName = zone.name
            isInTrustedZone = true
            hasWarnedOutsideTrustedZone = false
        } else if trustedLocations.isEmpty {
            // No trusted locations configured - treat as trusted
            currentLocationName = nil
            isInTrustedZone = true
        } else {
            // Outside all trusted zones
            currentLocationName = nil
            isInTrustedZone = false
        }
    }

    /// Called when sync is about to happen - warns if outside trusted zone
    /// Returns the name of the current trusted zone (nil if outside or no zones configured)
    func checkAndWarnIfNeeded() -> String? {
        // If no trusted locations configured, no warning needed
        guard hasTrustedLocations else { return nil }

        // If inside a trusted zone, return the name
        if isInTrustedZone {
            return currentLocationName
        }

        // Outside trusted zone - warn if we haven't recently
        if shouldShowWarning() {
            showOutsideTrustedZoneWarning()
        }

        return nil
    }

    /// Check if sync should be blocked based on current location and user settings
    /// Returns true if sync should be BLOCKED, false if sync is allowed
    func shouldBlockSync() -> Bool {
        // If no trusted locations configured, never block
        guard hasTrustedLocations else { return false }

        // If mode is warn only, never block
        guard syncMode == .blockSync else { return false }

        // Block if outside trusted zone
        return !isInTrustedZone
    }

    private func shouldShowWarning() -> Bool {
        // Don't warn if already warned recently
        if let lastWarning = lastWarningTime,
           Date().timeIntervalSince(lastWarning) < warningCooldown {
            return false
        }
        return !hasWarnedOutsideTrustedZone
    }

    private func showOutsideTrustedZoneWarning() {
        hasWarnedOutsideTrustedZone = true
        lastWarningTime = Date()

        let content = UNMutableNotificationContent()
        content.title = "Syncing Outside Trusted Zone"
        content.body = "Your wallet is syncing from an untrusted location. Add this location as trusted in Settings if this is intentional."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "outsideTrustedZone",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func loadLocations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let locations = try? JSONDecoder().decode([TrustedLocation].self, from: data) else {
            return
        }
        trustedLocations = locations
    }

    private func saveLocations() {
        guard let data = try? JSONEncoder().encode(trustedLocations) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - CLLocationManagerDelegate

extension TrustedLocationsManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion else { return }

        Task { @MainActor in
            // Find the trusted location for this region
            if let location = trustedLocations.first(where: { $0.id.uuidString == circularRegion.identifier }) {
                currentLocationName = location.name
                isInTrustedZone = true
                hasWarnedOutsideTrustedZone = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            // Check if we're still in any trusted zone
            if let location = lastKnownLocation {
                updateZoneStatus(for: location)
            } else {
                // No location data - assume outside
                currentLocationName = nil
                isInTrustedZone = trustedLocations.isEmpty
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            updateZoneStatus(for: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location failed - keep previous state
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Region monitoring failed - this can happen if too many regions are monitored
        // iOS limits to 20 regions per app
    }
}
