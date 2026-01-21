import Foundation
import ActivityKit

/// Manages Live Activity for sync progress in Dynamic Island
@MainActor
class SyncActivityManager: ObservableObject {
    static let shared = SyncActivityManager()

    @Published var isActivityRunning = false
    private var currentActivity: Activity<SyncActivityAttributes>?
    private var isStartingActivity = false

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
            print("Reusing existing sync Live Activity")
            return
        }

        let attributes = SyncActivityAttributes(walletName: "Monero One")
        let initialState = SyncActivityAttributes.ContentState(
            progress: 0,
            blocksRemaining: nil,
            isSynced: false,
            lastUpdated: Date()
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            isActivityRunning = true
            print("Started sync Live Activity")
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    /// Update the Live Activity with new sync progress
    func updateProgress(_ progress: Double, blocksRemaining: Int? = nil) {
        guard let activity = currentActivity else { return }

        let state = SyncActivityAttributes.ContentState(
            progress: progress,
            blocksRemaining: blocksRemaining,
            isSynced: progress >= 100,
            lastUpdated: Date()
        )

        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Mark sync as complete
    func markSynced() {
        guard let activity = currentActivity else { return }

        let state = SyncActivityAttributes.ContentState(
            progress: 100,
            blocksRemaining: 0,
            isSynced: true,
            lastUpdated: Date()
        )

        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
            )
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
        guard let activity = currentActivity else { return }

        let finalState = SyncActivityAttributes.ContentState(
            progress: 100,
            blocksRemaining: 0,
            isSynced: true,
            lastUpdated: Date()
        )

        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        currentActivity = nil
        isActivityRunning = false
    }
}
