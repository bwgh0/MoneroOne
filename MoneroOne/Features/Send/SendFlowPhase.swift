import Foundation

enum SendFlowPhase: Equatable {
    case address
    case amount
    case review
    case sending
    case success(txHash: String)
    case error(message: String)
}
