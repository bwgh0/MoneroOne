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
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published private(set) var currentTrustedLocationName: String?  // Name of current trusted zone (nil if outside)
    @Published private(set) var isSyncBlocked: Bool = false  // True when outside zone + block mode
    @Published private(set) var isOutsideTrustedZone: Bool = false  // True when outside zone (any mode)

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
        accuracyAuthorization = statusCheckManager?.accuracyAuthorization ?? .fullAccuracy
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

        // Observe connection stage — update live activity during early phases (noNetwork, reachingNode)
        walletManager.$connectionStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                self?.handleConnectionStageChange(stage)
            }
            .store(in: &cancellables)

        // Observe trusted location changes — use CombineLatest on the actual
        // @Published values so we read them AFTER they change (not on willChange).
        // Include isUnlocked so we recompute when wallet becomes available.
        Publishers.CombineLatest4(
            trustedLocationsManager.$syncMode,
            trustedLocationsManager.$isInTrustedZone,
            trustedLocationsManager.$trustedLocations,
            walletManager.$isUnlocked
        )
        .dropFirst() // Skip initial emission
        .receive(on: DispatchQueue.main)
        .sink { [weak self] mode, inZone, locations, unlocked in
            #if DEBUG
            NSLog("[TrustedSync] State changed — mode=\(mode.rawValue) inZone=\(inZone) locations=\(locations.count) unlocked=\(unlocked)")
            #endif
            self?.recomputeSyncState()
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
        locationManager?.showsBackgroundLocationIndicator = false

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

    /// Recompute sync state in response to settings changes (mode, zone, locations)
    private func recomputeSyncState() {
        guard let wallet = walletManager, wallet.isUnlocked else {
            #if DEBUG
            NSLog("[TrustedSync] recompute skipped — wallet nil or locked")
            #endif
            return
        }

        let outsideZone = trustedLocationsManager.hasTrustedLocations && !trustedLocationsManager.isInTrustedZone
        let wasBlocked = isSyncBlocked
        let shouldBlock = trustedLocationsManager.shouldBlockSync()

        #if DEBUG
        NSLog("[TrustedSync] recompute — outsideZone=\(outsideZone) wasBlocked=\(wasBlocked) shouldBlock=\(shouldBlock) syncMode=\(trustedLocationsManager.syncMode.rawValue) isInTrustedZone=\(trustedLocationsManager.isInTrustedZone) hasLocations=\(trustedLocationsManager.hasTrustedLocations)")
        #endif

        isOutsideTrustedZone = outsideZone
        isSyncBlocked = shouldBlock
        currentTrustedLocationName = trustedLocationsManager.isInTrustedZone ? trustedLocationsManager.currentLocationName : nil

        if shouldBlock && !wasBlocked {
            // Newly blocked — pause the actual sync engine
            #if DEBUG
            NSLog("[TrustedSync] BLOCKING sync — pausing wallet")
            #endif
            wallet.pauseSync()
            isSyncing = false
            if #available(iOS 16.2, *), isEnabled {
                SyncActivityManager.shared.markBlocked()
            }
        } else if shouldBlock {
            // Already blocked — ensure wallet stays paused
            if !wallet.isSyncBlocked {
                wallet.pauseSync()
            }
            if #available(iOS 16.2, *), isEnabled {
                SyncActivityManager.shared.markBlocked()
            }
        } else if wasBlocked {
            // Was blocked, now unblocked — resume sync
            #if DEBUG
            NSLog("[TrustedSync] UNBLOCKING sync — resuming wallet")
            #endif
            wallet.resumeSync()
            performSync()
        } else {
            // Not blocked before or after — just update location info on live activity
            if #available(iOS 16.2, *), isEnabled {
                switch wallet.syncState {
                case .synced:
                    SyncActivityManager.shared.markSynced(locationName: currentTrustedLocationName, isUntrusted: outsideZone)
                case .syncing(let progress, let remaining):
                    SyncActivityManager.shared.updateProgress(progress, blocksRemaining: remaining, locationName: currentTrustedLocationName, isUntrusted: outsideZone)
                default:
                    break
                }
            }
        }
    }

    /// Handle connection stage changes — show connecting on live activity during early phases
    private func handleConnectionStageChange(_ stage: ConnectionStage) {
        guard isEnabled else { return }
        // During early stages before SyncState moves to .connecting,
        // update the live activity to show connecting instead of stale "synced"
        switch stage {
        case .noNetwork, .reachingNode, .connecting, .loadingBlocks:
            if let wallet = walletManager, wallet.syncState == .idle || wallet.syncState == .connecting {
                if #available(iOS 16.2, *) {
                    Task {
                        await SyncActivityManager.shared.startActivity(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
                        SyncActivityManager.shared.markConnecting(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
                    }
                }
            }
        default:
            break
        }
    }

    private func performSync() {
        guard let wallet = walletManager, wallet.isUnlocked else { return }

        // Update trusted location status
        let outsideZone = trustedLocationsManager.hasTrustedLocations && !trustedLocationsManager.isInTrustedZone
        isOutsideTrustedZone = outsideZone

        // Check if sync should be blocked based on trusted location settings
        if trustedLocationsManager.shouldBlockSync() {
            // In block mode and outside trusted zone - pause sync engine and block
            wallet.pauseSync()
            isSyncBlocked = true
            isSyncing = false
            if #available(iOS 16.2, *), isEnabled {
                SyncActivityManager.shared.markBlocked()
            }
            return
        }

        // Ensure sync is unblocked
        if wallet.isSyncBlocked {
            wallet.resumeSync()
        }
        isSyncBlocked = false
        isSyncing = true

        // Check trusted location status and warn if needed (for warn-only mode)
        currentTrustedLocationName = trustedLocationsManager.checkAndWarnIfNeeded()

        Task {
            // 1. Start/reset Live Activity and show connecting
            if #available(iOS 16.2, *), isEnabled {
                await SyncActivityManager.shared.startActivity(locationName: currentTrustedLocationName, isUntrusted: outsideZone)
            }

            // 2. Restart sync state checking to detect new blocks
            wallet.startSync()

            // 3. Wait for refresh to complete
            await wallet.refresh()

            // 4. Directly mark as synced (bypasses race conditions from Combine subscription)
            if #available(iOS 16.2, *), isEnabled {
                SyncActivityManager.shared.markSynced(locationName: currentTrustedLocationName, isUntrusted: outsideZone)
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
        // Don't update live activity with sync progress when blocked
        guard !isSyncBlocked else { return }

        switch state {
        case .syncing(let progress, let remaining):
            isSyncing = true
            guard isEnabled else { return }
            if #available(iOS 16.2, *) {
                Task {
                    await SyncActivityManager.shared.startActivity(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
                    SyncActivityManager.shared.updateProgress(progress, blocksRemaining: remaining, locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
                }
            }

        case .synced:
            isSyncing = false
            lastSyncTime = Date()
            guard isEnabled else { return }
            if #available(iOS 16.2, *) {
                SyncActivityManager.shared.markSynced(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
            }

        case .error:
            isSyncing = false
            break

        case .connecting:
            isSyncing = true
            guard isEnabled else { return }
            if #available(iOS 16.2, *) {
                Task {
                    await SyncActivityManager.shared.startActivity(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
                    SyncActivityManager.shared.markConnecting(locationName: currentTrustedLocationName, isUntrusted: isOutsideTrustedZone)
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

    var needsPreciseLocation: Bool {
        accuracyAuthorization == .reducedAccuracy
    }
}

// MARK: - CLLocationManagerDelegate
extension TrustedLocationSyncManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            // Always update the published status so UI reflects changes
            authorizationStatus = status
            accuracyAuthorization = accuracy

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
