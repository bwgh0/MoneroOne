import Foundation
import ActivityKit

/// Shared Live Activity attributes for sync progress
/// Used by both main app and widget extension
/// Note: Requires iOS 16.1+ - main app wraps usages with availability checks
public struct SyncActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var blocksRemaining: Int?
        public var isSynced: Bool
        public var isConnecting: Bool
        public var lastUpdated: Date

        public init(progress: Double, blocksRemaining: Int? = nil, isSynced: Bool, isConnecting: Bool = false, lastUpdated: Date) {
            self.progress = progress
            self.blocksRemaining = blocksRemaining
            self.isSynced = isSynced
            self.isConnecting = isConnecting
            self.lastUpdated = lastUpdated
        }
    }

    public var walletName: String

    public init(walletName: String) {
        self.walletName = walletName
    }
}
