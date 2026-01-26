import Foundation

extension Array {
    /// Binary search for nearest element in a sorted array by timestamp
    /// - Parameters:
    ///   - target: The date to find the nearest match for
    ///   - timestampKeyPath: KeyPath to the timestamp property
    /// - Returns: The element closest to the target, or nil if array is empty
    /// - Complexity: O(log n) vs O(n) for linear search
    func nearestByTimestamp(to target: Date, timestampKeyPath: KeyPath<Element, Date>) -> Element? {
        guard !isEmpty else { return nil }
        guard count > 1 else { return first }

        var low = 0
        var high = count - 1

        // Binary search to find insertion point
        while low < high {
            let mid = (low + high) / 2
            if self[mid][keyPath: timestampKeyPath] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Compare with neighbor to find closest
        if low == 0 { return self[0] }
        if low >= count { return self[count - 1] }

        let prevDist = abs(self[low - 1][keyPath: timestampKeyPath].timeIntervalSince(target))
        let currDist = abs(self[low][keyPath: timestampKeyPath].timeIntervalSince(target))

        return prevDist < currDist ? self[low - 1] : self[low]
    }
}
