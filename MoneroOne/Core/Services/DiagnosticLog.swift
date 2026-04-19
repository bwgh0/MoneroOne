import Foundation
import os.log

// MARK: - Previous-crash bridge file
//
// Historically a custom signal handler wrote a truncated Swift backtrace
// to this file and re-raised the signal so iOS would still produce a
// crash report. The re-raise pattern wiped the real crashing-thread state
// from the resulting .ips (iOS captures post-handler state, which is
// typically just the main runloop), so every crash looked like a mystery.
//
// The signal handler is gone. Apple's default reporter + the dSYM that
// CI uploads with each archive gives proper symbolicated stacks in Xcode
// Organizer and in the device's Analytics Data .ips files — strictly
// more info than our handler ever provided.
//
// We still `loadPreviousCrash()` so any file left over from older builds
// with the handler installed surfaces once at next launch, then gets
// deleted. Safe to remove this entirely once none of those builds are in
// the wild anymore.

private let crashLogPath: String = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("crash_report.txt").path
}()

/// In-memory diagnostic log buffer for troubleshooting sync/network issues.
/// Captures connection and sync events so users can share them with support.
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    private var entries: [(Date, String)] = []
    private let maxEntries = 500
    private let queue = DispatchQueue(label: "one.monero.diagnosticlog")
    private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "Diagnostic")

    private init() {
        loadPreviousCrash()
    }

    /// Load crash report from previous session if one exists
    private func loadPreviousCrash() {
        guard FileManager.default.fileExists(atPath: crashLogPath),
              let data = FileManager.default.contents(atPath: crashLogPath),
              let report = String(data: data, encoding: .utf8),
              !report.isEmpty else { return }

        // Prepend to log so it shows at the top of the export
        queue.sync {
            entries.insert((Date(), "--- PREVIOUS CRASH ---"), at: 0)
            for line in report.components(separatedBy: "\n") where !line.isEmpty {
                entries.insert((Date(), line), at: entries.count > 0 ? 1 : 0)
            }
            entries.insert((Date(), "--- END CRASH ---"), at: entries.count > 1 ? 2 : 0)
        }

        // Delete the crash file so we don't show it again
        try? FileManager.default.removeItem(atPath: crashLogPath)
    }

    func log(_ message: String) {
        let now = Date()
        logger.info("\(message)")
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.append((now, message))
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func export() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = []
        lines.append("MoneroOne Diagnostic Log")
        lines.append("Exported: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Device: \(deviceInfo())")
        lines.append("App Version: \(appVersion())")
        lines.append(String(repeating: "-", count: 60))

        queue.sync {
            for (date, message) in entries {
                lines.append("[\(formatter.string(from: date))] \(message)")
            }
        }

        if lines.count <= 5 {
            lines.append("(no log entries)")
        }

        return lines.joined(separator: "\n")
    }

    func clear() {
        queue.sync {
            entries.removeAll()
        }
    }

    private func deviceInfo() -> String {
        let device = ProcessInfo.processInfo
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return "\(machine), iOS \(device.operatingSystemVersionString)"
    }

    private func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
