import Foundation
import CoreLocation
import Combine

/// Manages wallet sync within trusted location zones
/// Uses geofenced locations to determine when sync is safe to run
@MainActor
class TrustedLocationSyncManager: NSObject, ObservableObject {
    static let shared = TrustedLocationSyncManager()

    @Published var isEnabled: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastSyncTime: Date?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var currentTrustedLocationName: String?  // Name of current trusted zone (nil if outside)

    private var locationManager: CLLocationManager?
    private var statusCheckManager: CLLocationManager? // For checking status without starting updates
    private var walletManager: WalletManager?
    private let enabledKey = "backgroundSyncEnabled"

    // Trusted locations manager
    private let trustedLocationsManager = TrustedLocationsManager.shared

    // Timer-based polling for when stationary (location updates won't trigger)
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 120 // 2 minutes

    private override init() {
        super.init()
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        // Create a temporary manager just to check authorization status
        checkAuthorizationStatus()
    }

    /// Check the current authorization status without starting location updates
    private func checkAuthorizationStatus() {
        if statusCheckManager == nil {
            statusCheckManager = CLLocationManager()
            statusCheckManager?.delegate = self
        }
        authorizationStatus = statusCheckManager?.authorizationStatus ?? .notDetermined
    }

    func configure(walletManager: WalletManager) {
        self.walletManager = walletManager

        // Observe sync state changes to update Live Activity
        walletManager.$syncState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleSyncStateChange(state)
            }
            .store(in: &cancellables)

        if isEnabled {
            startLocationSync()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        if enabled {
            startLocationSync()
        } else {
            stopLocationSync()
            // End Live Activity when disabled
            if #available(iOS 16.2, *) {
                SyncActivityManager.shared.endActivity()
            }
        }
    }

    func startLocationSync() {
        guard locationManager == nil else { return }

        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers // Low accuracy = less battery
        locationManager?.distanceFilter = 500 // Only update every 500m
        locationManager?.pausesLocationUpdatesAutomatically = false
        locationManager?.showsBackgroundLocationIndicator = true

        // Request always authorization for trusted zone monitoring
        // Background updates will be enabled in the authorization callback
        locationManager?.requestAlwaysAuthorization()
    }

    func stopLocationSync() {
        stopPollTimer()
        locationManager?.stopUpdatingLocation()
        locationManager?.stopMonitoringSignificantLocationChanges()
        locationManager = nil
        isSyncing = false
    }

    private func performSync() {
        guard let wallet = walletManager, wallet.isUnlocked else { return }

        // Check if sync should be blocked based on trusted location settings
        if trustedLocationsManager.shouldBlockSync() {
            // In block mode and outside trusted zone - skip sync
            isSyncing = false
            return
        }

        isSyncing = true

        // Check trusted location status and warn if needed (for warn-only mode)
        currentTrustedLocationName = trustedLocationsManager.checkAndWarnIfNeeded()

        Task {
            // 1. Start/reset Live Activity and show connecting
            if #available(iOS 16.2, *), isEnabled {
                await SyncActivityManager.shared.startActivity(locationName: currentTrustedLocationName)
                // startActivity() already sets isConnecting: true
            }

            // 2. Restart sync state checking to detect new blocks
            wallet.startSync()

            // 3. Wait for refresh to complete
            await wallet.refresh()

            // 4. Directly mark as synced (bypasses race conditions from Combine subscription)
            if #available(iOS 16.2, *), isEnabled {
                SyncActivityManager.shared.markSynced(locationName: currentTrustedLocationName)
            }

            isSyncing = false
            lastSyncTime = Date()
        }
    }

    private func startPollTimer() {
        stopPollTimer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performSync()
            }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func handleSyncStateChange(_ state: WalletManager.SyncState) {
        switch state {
        case .syncing(let progress, let remaining):
            isSyncing = true
            guard isEnabled else { return }
            if #available(iOS 16.2, *) {
                Task {
                    // Ensure activity is started/reconnected before updating progress
                    await SyncActivityManager.shared.startActivity()
                    SyncActivityManager.shared.updateProgress(progress, blocksRemaining: remaining)
                }
            }

        case .synced:
            isSyncing = false
            lastSyncTime = Date()
            guard isEnabled else { return }
            if #available(iOS 16.2, *) {
                SyncActivityManager.shared.markSynced()
            }

        case .error:
            isSyncing = false
            // Keep activity showing but could add error state
            break

        case .connecting:
            isSyncing = true
            guard isEnabled else { return }
            // Start Live Activity and show connecting state
            if #available(iOS 16.2, *) {
                Task {
                    await SyncActivityManager.shared.startActivity()
                    SyncActivityManager.shared.markConnecting()
                }
            }

        case .idle:
            isSyncing = false
            break
        }
    }

    var needsAuthorization: Bool {
        let status = authorizationStatus
        return status == .notDetermined || status == .denied || status == .restricted
    }
}

// MARK: - CLLocationManagerDelegate
extension TrustedLocationSyncManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // Always update the published status so UI reflects changes
            authorizationStatus = status

            // Only act on the main location manager (not the status check manager)
            guard manager === locationManager else { return }

            switch status {
            case .authorizedAlways:
                // Now we can safely enable background updates
                locationManager?.allowsBackgroundLocationUpdates = true
                locationManager?.startUpdatingLocation()
                // Start timed polling for when stationary
                startPollTimer()
            case .authorizedWhenInUse:
                // Need "Always" for trusted zone monitoring - prompt upgrade
                locationManager?.requestAlwaysAuthorization()
            case .denied, .restricted:
                // User denied - disable feature
                setEnabled(false)
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Location received - update trusted zone status and sync
        Task { @MainActor in
            // Update trusted location status with current location
            if let location = locations.last {
                trustedLocationsManager.updateZoneStatus(for: location)
            }
            performSync()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location failed - still try to sync if we can
        Task { @MainActor in
            performSync()
        }
    }
}
