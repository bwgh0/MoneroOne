import Foundation
import os.log

// MARK: - Crash Handler (file-level for signal safety)

private let crashLogPath: String = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("crash_report.txt").path
}()

private func crashSignalHandler(signal: Int32) {
    let names: [Int32: String] = [SIGABRT: "SIGABRT", SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGILL: "SIGILL"]
    let name = names[signal] ?? "SIGNAL(\(signal))"
    let timestamp = ISO8601DateFormatter().string(from: Date())

    // Get thread backtrace — limited but better than nothing
    var info = "CRASH: \(name) at \(timestamp)\n"
    info += "Thread: \(Thread.current)\n"
    for symbol in Thread.callStackSymbols.prefix(20) {
        info += "\(symbol)\n"
    }

    // Write directly to file (signal-safe: no ObjC, no allocations beyond the string above)
    if let data = info.data(using: .utf8) {
        FileManager.default.createFile(atPath: crashLogPath, contents: data)
    }

    // Re-raise to let the default handler produce the real crash report
    Darwin.signal(signal, SIG_DFL)
    Darwin.raise(signal)
}

/// In-memory diagnostic log buffer for troubleshooting sync issues.
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

    /// Install signal handlers and exception handler. Call once at app launch.
    func installCrashHandlers() {
        Darwin.signal(SIGABRT, crashSignalHandler)
        Darwin.signal(SIGSEGV, crashSignalHandler)
        Darwin.signal(SIGBUS, crashSignalHandler)
        Darwin.signal(SIGFPE, crashSignalHandler)
        Darwin.signal(SIGILL, crashSignalHandler)

        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            var info = "UNCAUGHT EXCEPTION at \(timestamp)\n"
            info += "Name: \(exception.name.rawValue)\n"
            info += "Reason: \(exception.reason ?? "none")\n"
            for symbol in exception.callStackSymbols.prefix(20) {
                info += "\(symbol)\n"
            }
            if let data = info.data(using: .utf8) {
                FileManager.default.createFile(atPath: crashLogPath, contents: data)
            }
        }
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
