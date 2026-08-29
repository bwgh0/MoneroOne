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

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
