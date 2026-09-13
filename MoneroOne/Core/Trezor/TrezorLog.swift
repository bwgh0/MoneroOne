import Foundation

/// Thread-safe file logger for Trezor debugging.
/// Writes to Documents/trezor_debug.log on the device.
/// Pull with: xcrun devicectl device copy from --device <ID> --source Documents/trezor_debug.log --destination /tmp/trezor_debug.log --domain-type appDataContainer --domain-identifier one.monero.MoneroOne
enum TrezorLog {
    private static let queue = DispatchQueue(label: "trezor.log", qos: .utility)
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let logFile: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("trezor_debug.log")
    }()

    /// Clear the log file
    static func clear() {
        queue.sync {
            guard let url = logFile else { return }
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Above this the log is restarted rather than grown forever. Trezor
    /// sessions are chatty (196 call sites) and this file used to have no
    /// bound at all.
    private static let maxFileSize: Int = 512 * 1024

    /// Append a log line (supports format strings like NSLog)
    ///
    /// Kept in release builds on purpose — it is the primary diagnostic for
    /// hardware-wallet pairing problems in the field. It is, however, kept out
    /// of device backups and size-capped, and the console mirror is
    /// debug-only: some call sites log balances, and the unified log is
    /// readable via sysdiagnose or a tethered Mac.
    static func log(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        #if DEBUG
        NSLog("[Trezor] %@", message)
        #endif

        queue.async {
            guard let url = logFile else { return }
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                let size = (try? fm.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.size] as? Int } ?? 0
                if size > maxFileSize {
                    try? fm.removeItem(at: url)
                    try? data.write(to: url)
                    excludeFromBackup(url)
                    return
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
                excludeFromBackup(url)
            }
        }
    }

    // MARK: - Export

    /// Lines that are pure wire chatter or carry data support never needs.
    private static let droppedLineMarkers = [
        "writeRawChunk:",          // raw BLE chunk hex
        "processRawChunk:",        // raw BLE chunk hex
        "Received 244 bytes",      // per-chunk receive notice
        "readTHPResponse: ACK",    // ABP acks
        "/call hex body",          // protobuf payload prefix
        "[BLE] Other device:",     // nearby BLE devices
        "[displayBalance]",        // debug-only balance traces
    ]

    /// Belt and braces on top of the call-site hygiene: anything that
    /// looks like a Monero address (standard, subaddress, integrated) or
    /// a 64-hex key/hash is masked before the text leaves the device.
    private static let addressRegex = try! NSRegularExpression(
        pattern: "\\b[48][1-9A-HJ-NP-Za-km-z]{94}(?:[1-9A-HJ-NP-Za-km-z]{11})?\\b")
    private static let hex64Regex = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b")

    /// Reduce a raw Trezor log to what a support engineer needs: BLE and
    /// THP step outcomes, bridge message types, session milestones and
    /// error strings. Pure function so it can be unit-tested.
    static func sanitize(_ text: String) -> String {
        var out: [String] = []
        out.reserveCapacity(1024)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if droppedLineMarkers.contains(where: { s.contains($0) }) { continue }
            var masked = s
            for (regex, token) in [(addressRegex, "<address>"), (hex64Regex, "<hex64>")] {
                masked = regex.stringByReplacingMatches(
                    in: masked, range: NSRange(masked.startIndex..., in: masked), withTemplate: token)
            }
            out.append(masked)
        }
        return out.joined(separator: "\n")
    }

    /// The on-device log, sanitized and trimmed to its newest `maxBytes`
    /// (the most recent pairing/session is what matters). Nil when the
    /// user has never used a Trezor.
    static func exportSanitized(maxBytes: Int = 300 * 1024) -> String? {
        guard let url = logFile else { return nil }
        let raw: String? = queue.sync { try? String(contentsOf: url, encoding: .utf8) }
        guard let raw, !raw.isEmpty else { return nil }
        let sanitized = sanitize(raw)
        guard sanitized.utf8.count > maxBytes else { return sanitized }
        // Trim at a line boundary from the front.
        let dropCount = sanitized.utf8.count - maxBytes
        let tail = sanitized.dropFirst(dropCount)
        if let firstBreak = tail.firstIndex(of: "\n") {
            return "(older lines trimmed)\n" + tail[tail.index(after: firstBreak)...]
        }
        return String(tail)
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
