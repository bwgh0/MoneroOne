import Foundation
import ActivityKit

/// Shared Live Activity attributes for sync progress
/// Used by both main app and widget extension
public struct SyncActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var blocksRemaining: Int?
        public var isSynced: Bool
        public var lastUpdated: Date

        public init(progress: Double, blocksRemaining: Int? = nil, isSynced: Bool, lastUpdated: Date) {
            self.progress = progress
            self.blocksRemaining = blocksRemaining
            self.isSynced = isSynced
            self.lastUpdated = lastUpdated
        }
    }

    public var walletName: String

    public init(walletName: String) {
        self.walletName = walletName
    }
}
