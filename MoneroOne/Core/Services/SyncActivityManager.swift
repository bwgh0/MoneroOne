import Foundation
import ActivityKit

/// Manages Live Activity for sync progress in Dynamic Island
@available(iOS 16.2, *)
@MainActor
class SyncActivityManager: ObservableObject {
    static let shared = SyncActivityManager()

    @Published var isActivityRunning = false
    private var currentActivity: Activity<SyncActivityAttributes>?
    private var isStartingActivity = false
    private var refreshTimer: Timer?
    private var isSynced = false

    private init() {}

    /// Start a new Live Activity for sync progress
    func startActivity() async {
        // Prevent concurrent calls
        guard !isStartingActivity else { return }
        isStartingActivity = true
        defer { isStartingActivity = false }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities not enabled")
            return
        }

        // Check for existing activity first - reuse if found
        if let existing = Activity<SyncActivityAttributes>.activities.first {
            currentActivity = existing
            isActivityRunning = true
            isSynced = false  // Reset sync state for new sync cycle
            print("Reusing existing sync Live Activity")

            // Update activity to show connecting state (not stale "Synced" from previous cycle)
            let state = SyncActivityAttributes.ContentState(
                progress: 0,
                blocksRemaining: nil,
                isSynced: false,
                isConnecting: true,
                lastUpdated: Date()
            )
            Task {
                await existing.update(ActivityContent(state: state, staleDate: nil))
            }

            startRefreshTimer()
            return
        }

        let attributes = SyncActivityAttributes(walletName: "Monero One")
        let initialState = SyncActivityAttributes.ContentState(
            progress: 0,
            blocksRemaining: nil,
            isSynced: false,
            isConnecting: true,
            lastUpdated: Date()
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            isActivityRunning = true
            isSynced = false
            print("Started sync Live Activity")
            startRefreshTimer()
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    /// Update the Live Activity with new sync progress
    func updateProgress(_ progress: Double, blocksRemaining: Int? = nil) {
        guard let activity = currentActivity else { return }

        isSynced = false

        let state = SyncActivityAttributes.ContentState(
            progress: progress,
            blocksRemaining: blocksRemaining,
            isSynced: false,
            isConnecting: false,
            lastUpdated: Date()
        )

        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Mark sync as complete - Activity stays visible until next sync cycle
    func markSynced() {
        guard let activity = currentActivity else { return }

        isSynced = true

        let state = SyncActivityAttributes.ContentState(
            progress: 100,
            blocksRemaining: 0,
            isSynced: true,
            isConnecting: false,
            lastUpdated: Date()
        )

        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)  // No stale date - stays visible
            )
        }
    }

    /// Mark activity as connecting (checking for new blocks)
    func markConnecting() {
        guard let activity = currentActivity else { return }

        isSynced = false

        let state = SyncActivityAttributes.ContentState(
            progress: 0,
            blocksRemaining: nil,
            isSynced: false,
            isConnecting: true,
            lastUpdated: Date()
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// End the Live Activity (fire and forget)
    func endActivity() {
        Task {
            await endActivityAsync()
        }
    }

    /// End the Live Activity and wait for completion
    func endActivityAsync() async {
        stopRefreshTimer()

        guard let activity = currentActivity else { return }

        let finalState = SyncActivityAttributes.ContentState(
            progress: 100,
            blocksRemaining: 0,
            isSynced: true,
            isConnecting: false,
            lastUpdated: Date()
        )

        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        currentActivity = nil
        isActivityRunning = false
        isSynced = false
    }

    // MARK: - Refresh Timer

    /// Start timer to periodically refresh lastUpdated when synced (~2 min to match XMR block time)
    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired()
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func timerFired() {
        // Only refresh timestamp when synced
        guard isSynced else { return }
        markSynced()
    }
}
