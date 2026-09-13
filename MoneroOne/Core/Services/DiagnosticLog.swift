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

/// Disk-backed diagnostic log for troubleshooting sync/network issues.
/// Captures connection and sync events so users can share them with support.
///
/// Lines are appended to a file as they arrive, so the log survives app
/// restarts and background kills — the events leading up to a problem are
/// usually in the session *before* the user thinks to export. One rotated
/// previous-generation file is kept, so an export has history even right
/// after a rotation.
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "one.monero.diagnosticlog")
    private let logger = Logger(subsystem: "one.monero.MoneroOne", category: "Diagnostic")

    /// Rotate when the current file grows past this. The previous file is
    /// kept, so total retention is at most twice this — small enough to
    /// email, big enough for several sessions of sync events.
    private let maxFileSize = 256 * 1024

    private let currentFileURL: URL
    private let previousFileURL: URL

    /// Only touched on `queue` (DateFormatter is not thread-safe). Includes
    /// the date: entries now span multiple days, not one session.
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("DiagnosticLog", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.excludeFromBackup(dir)
        currentFileURL = dir.appendingPathComponent("diagnostic.log")
        previousFileURL = dir.appendingPathComponent("diagnostic.previous.log")

        let sessionHeader = "=== Session start — v\(appVersion()), \(deviceInfo()) ==="
        queue.async { [self] in
            appendLine(sessionHeader, at: Date())
        }
        loadPreviousCrash()
    }

    /// Load crash report from previous session if one exists
    private func loadPreviousCrash() {
        guard FileManager.default.fileExists(atPath: crashLogPath),
              let data = FileManager.default.contents(atPath: crashLogPath),
              let report = String(data: data, encoding: .utf8),
              !report.isEmpty else { return }

        queue.async { [self] in
            let now = Date()
            appendLine("--- PREVIOUS CRASH ---", at: now)
            for line in report.components(separatedBy: "\n") where !line.isEmpty {
                appendLine(line, at: now)
            }
            appendLine("--- END CRASH ---", at: now)
        }

        // Delete the crash file so we don't show it again
        try? FileManager.default.removeItem(atPath: crashLogPath)
    }

    func log(_ message: String) {
        let now = Date()
        let message = Self.redactingCredentials(in: message)
        logger.info("\(message)")
        queue.async { [weak self] in
            self?.appendLine(message, at: now)
        }
    }

    func export() -> String {
        var lines: [String] = []
        lines.append("MoneroOne Diagnostic Log")
        lines.append("Exported: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Device: \(deviceInfo())")
        lines.append("App Version: \(appVersion())")
        // Say plainly what is in here. This file gets emailed to support, and
        // the user should be able to see the scope of what they're sending
        // rather than infer it from 500 lines of log.
        lines.append("Contains: device model, iOS/app version, the node URLs this app connected to, sync progress, wallet-engine error messages, and (if you use a Trezor) the Bluetooth pairing and hardware-session steps with their outcomes.")
        lines.append("Never contains: your seed phrase, private keys, PIN, node passwords, wallet addresses, balances, or the names of nearby Bluetooth devices.")
        lines.append(String(repeating: "-", count: 60))

        var body = ""
        queue.sync {
            for url in [previousFileURL, currentFileURL] {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    body += text
                }
            }
        }

        if body.isEmpty {
            body = "(no log entries)\n"
        }

        // The Trezor log is where every hardware-wallet failure so far has
        // actually been diagnosable (BLE/THP step outcomes, bridge message
        // types, session errors). Until it shipped in the export, that
        // needed a development build on the user's phone.
        var trezorSection = ""
        if let trezor = TrezorLog.exportSanitized() {
            trezorSection = "\n" + String(repeating: "-", count: 60) + "\n"
                + "Trezor log — Bluetooth pairing and hardware-session protocol events (message types, step outcomes, errors). Raw payloads, nearby device names, addresses and balances are stripped.\n"
                + String(repeating: "-", count: 60) + "\n"
                + trezor + "\n"
        }

        return lines.joined(separator: "\n") + "\n" + body + trezorSection
    }

    /// Same content as `export()`, written to a temp file so the share
    /// sheet offers a `.txt` attachment instead of a wall of pasted text
    /// (the export can run to several hundred KB once a Trezor log is in).
    func exportFile() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneroOne-diagnostic-\(stamp).txt")
        do {
            try export().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: currentFileURL)
            try? FileManager.default.removeItem(at: previousFileURL)
        }
    }

    /// Strip `user:password@` out of any URL in a log line.
    ///
    /// Node URLs themselves are kept — they're the most useful thing in a
    /// sync-problem report — but this log gets emailed to support, so
    /// credentials embedded in a custom node URL must not ride along. Applied
    /// at the single logging choke point rather than per call site.
    static func redactingCredentials(in message: String) -> String {
        guard message.contains("://") else { return message }
        guard let regex = try? NSRegularExpression(pattern: "(?<=://)[^/@\\s]+:[^/@\\s]+@") else {
            return message
        }
        return regex.stringByReplacingMatches(
            in: message,
            range: NSRange(message.startIndex..., in: message),
            withTemplate: "***@"
        )
    }

    /// Must be called on `queue`.
    private func appendLine(_ message: String, at date: Date) {
        guard let data = "[\(timestampFormatter.string(from: date))] \(message)\n".data(using: .utf8) else { return }

        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: currentFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentFileURL, options: .atomic)
        }
    }

    /// Must be called on `queue`.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: currentFileURL.path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard size > maxFileSize else { return }
        try? fm.removeItem(at: previousFileURL)
        try? fm.moveItem(at: currentFileURL, to: previousFileURL)
    }

    /// The log records node URLs and sync history — useful to support, but
    /// nothing that should ride along into iCloud/local device backups.
    /// Excluding the directory covers every file created inside it.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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
