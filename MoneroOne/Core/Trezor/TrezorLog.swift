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

    /// Append a log line (supports format strings like NSLog)
    static func log(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        // Also NSLog for when we can get console
        NSLog("[Trezor] %@", message)

        queue.async {
            guard let url = logFile else { return }
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
