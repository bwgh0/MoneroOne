import Foundation
import CoreLocation
import Combine

/// Uses location services to keep app alive for background sync
/// Location data is NOT used or stored - only used to maintain background execution
@MainActor
class BackgroundSyncManager: NSObject, ObservableObject {
    static let shared = BackgroundSyncManager()

    @Published var isEnabled: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastSyncTime: Date?

    private var locationManager: CLLocationManager?
    private var walletManager: WalletManager?
    private let enabledKey = "backgroundSyncEnabled"

    private override init() {
        super.init()
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
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
            startBackgroundSync()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        if enabled {
            startBackgroundSync()
        } else {
            stopBackgroundSync()
        }
    }

    func startBackgroundSync() {
        guard locationManager == nil else { return }

        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers // Low accuracy = less battery
        locationManager?.distanceFilter = 500 // Only update every 500m
        locationManager?.allowsBackgroundLocationUpdates = true
        locationManager?.pausesLocationUpdatesAutomatically = false
        locationManager?.showsBackgroundLocationIndicator = false // Hide blue bar

        // Request always authorization for background
        locationManager?.requestAlwaysAuthorization()
    }

    func stopBackgroundSync() {
        locationManager?.stopUpdatingLocation()
        locationManager?.stopMonitoringSignificantLocationChanges()
        locationManager = nil
        isSyncing = false
    }

    private func performSync() {
        guard let wallet = walletManager, wallet.isUnlocked else { return }

        isSyncing = true
        wallet.refresh()
        lastSyncTime = Date()

        // Start Live Activity if not already running
        if isEnabled && !SyncActivityManager.shared.isActivityRunning {
            SyncActivityManager.shared.startActivity()
        }

        // Mark sync as done after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isSyncing = false
        }
    }

    private func handleSyncStateChange(_ state: WalletManager.SyncState) {
        guard isEnabled else { return }

        switch state {
        case .syncing(let progress, let remaining):
            // Start Live Activity if not running
            if !SyncActivityManager.shared.isActivityRunning {
                SyncActivityManager.shared.startActivity()
            }
            // Update Live Activity with progress
            SyncActivityManager.shared.updateProgress(progress, blocksRemaining: remaining)

        case .synced:
            // Mark as synced
            SyncActivityManager.shared.markSynced()

        case .error:
            // Keep activity showing but could add error state
            break

        case .connecting:
            // Start Live Activity when connecting
            if !SyncActivityManager.shared.isActivityRunning {
                SyncActivityManager.shared.startActivity()
            }

        case .idle:
            break
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager?.authorizationStatus ?? .notDetermined
    }

    var needsAuthorization: Bool {
        let status = authorizationStatus
        return status == .notDetermined || status == .denied || status == .restricted
    }
}

// MARK: - CLLocationManagerDelegate
extension BackgroundSyncManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways:
                // Perfect - start location updates for background execution
                manager.startUpdatingLocation()
            case .authorizedWhenInUse:
                // Need "Always" for background - prompt upgrade
                manager.requestAlwaysAuthorization()
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
        // Location received - we don't care about the actual location
        // This callback keeps our app alive - use it to sync!
        Task { @MainActor in
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
