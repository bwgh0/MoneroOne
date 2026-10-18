import Foundation

enum SendFlowPhase: Equatable {
    case address
    case amount
    case review
    case sending
    case success(txHash: String)
    case error(message: String)
}

/// A step pushed on the send flow's navigation stack. The address step is the
/// stack's root, so it has no case here.
enum SendFlowStep: Hashable {
    case amount
    case review
    /// Sending, success and failure. It has no way back.
    case status
}

extension SendFlowPhase {
    /// The steps on the stack above the address step while this phase shows.
    var stackPath: [SendFlowStep] {
        switch self {
        case .address: return []
        case .amount: return [.amount]
        case .review: return [.amount, .review]
        case .sending, .success, .error: return [.amount, .review, .status]
        }
    }

    /// The phase after the system back button or the edge swipe pops the
    /// stack to `path`. Pushes go through the phase, so only a shorter path
    /// changes it.
    func popped(to path: [SendFlowStep]) -> SendFlowPhase {
        guard path.count < stackPath.count else { return self }
        switch path.last {
        case nil: return .address
        case .amount: return .amount
        case .review: return .review
        case .status: return self
        }
    }
}
