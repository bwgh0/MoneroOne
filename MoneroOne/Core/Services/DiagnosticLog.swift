import Foundation
import os.log

/// In-memory diagnostic log buffer for troubleshooting sync issues.
/// Captures connection and sync events so users can share them with support.
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    private var entries: [(Date, String)] = []
    private let maxEntries = 500
    private let queue = DispatchQueue(label: "one.monero.diagnosticlog")
    private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "Diagnostic")

    private init() {}

    func log(_ message: String) {
        let now = Date()
        logger.info("\(message)")
        queue.sync {
            entries.append((now, message))
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
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
