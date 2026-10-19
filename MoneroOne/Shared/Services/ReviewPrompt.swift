import StoreKit
import SwiftUI

/// When the app asks for Apple's review prompt: once per install, on the
/// wallet home after the first send that went out. A tap on Settings > Rate
/// Monero One counts as done too, so a person who rated there is never asked.
///
/// Two flags in UserDefaults hold the state. `pending`: a send went out and
/// the prompt waits for the home. `done`: the prompt was asked for, or the
/// person opened the review page from Settings. After `done` nothing asks
/// again.
struct ReviewPromptGate {
    static let pendingKey = "reviewPromptPending"
    static let doneKey = "reviewPromptDone"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDone: Bool { defaults.bool(forKey: Self.doneKey) }

    /// A send went out and the home has not asked for the prompt yet.
    var isPending: Bool { !isDone && defaults.bool(forKey: Self.pendingKey) }

    /// The send flow moved to `phase`. Only `.success` (the transaction was
    /// submitted) counts. An error, a step back or a closed sheet does
    /// nothing.
    func sendPhaseChanged(to phase: SendFlowPhase) {
        guard case .success = phase, !isDone else { return }
        defaults.set(true, forKey: Self.pendingKey)
    }

    /// Settings > Rate Monero One opened the App Store review page.
    func ratedFromSettings() {
        markDone()
    }

    /// True once: a send is pending and the home is on screen, unlocked and
    /// idle, so the caller asks for the prompt now. It records `done` first,
    /// and no later call returns true.
    func claim(homeIsIdle: Bool) -> Bool {
        guard homeIsIdle, isPending else { return false }
        markDone()
        return true
    }

    private func markDone() {
        defaults.set(true, forKey: Self.doneKey)
        defaults.removeObject(forKey: Self.pendingKey)
    }
}

/// Asks for Apple's review prompt on the wallet home when
/// ``ReviewPromptGate`` has a send pending. The home must be idle (nothing
/// open on it), the app active, and nothing presented over the root (a
/// sheet, an alert, a sheet that is still closing) for about a second.
private struct ReviewPromptAfterSend: ViewModifier {
    let isIdle: Bool
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: isIdle && scenePhase == .active) { [isIdle, scenePhase] in
            guard isIdle, scenePhase == .active else { return }
            let gate = ReviewPromptGate()
            var quietChecks = 0
            while gate.isPending {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                quietChecks = SendRequestPresenter.isSheetShowing ? 0 : quietChecks + 1
                if quietChecks >= 2, gate.claim(homeIsIdle: true) {
                    requestReview()
                    return
                }
            }
        }
    }
}

extension View {
    /// For the wallet home: asks for Apple's review prompt after the first
    /// successful send. `isIdle`: unlocked, with no sheet, History, wallet
    /// list or pushed screen open on the home.
    func requestsReviewAfterSend(isIdle: Bool) -> some View {
        modifier(ReviewPromptAfterSend(isIdle: isIdle))
    }
}
