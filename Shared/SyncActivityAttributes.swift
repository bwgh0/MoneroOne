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
        public var trustedLocationName: String?  // Name of current trusted zone (e.g., "Home")
        public var isBlocked: Bool  // Sync blocked — outside trusted zone in block mode
        public var isUntrustedLocation: Bool  // Syncing from outside trusted zone (warn mode)

        public init(progress: Double, blocksRemaining: Int? = nil, isSynced: Bool, isConnecting: Bool = false, lastUpdated: Date, trustedLocationName: String? = nil, isBlocked: Bool = false, isUntrustedLocation: Bool = false) {
            self.progress = progress
            self.blocksRemaining = blocksRemaining
            self.isSynced = isSynced
            self.isConnecting = isConnecting
            self.lastUpdated = lastUpdated
            self.trustedLocationName = trustedLocationName
            self.isBlocked = isBlocked
            self.isUntrustedLocation = isUntrustedLocation
        }
    }

    public var walletName: String

    public init(walletName: String) {
        self.walletName = walletName
    }
}
