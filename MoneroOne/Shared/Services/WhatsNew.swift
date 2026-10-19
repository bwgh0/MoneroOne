import SwiftUI

/// A major.minor app version. It compares as numbers, so 1.10 is after 1.9.
struct NotesVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Reads "1.1", "1.1.0" or "1.10.2" as major.minor. Nil without two
    /// leading numbers.
    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    /// This build's CFBundleShortVersionString as major.minor.
    static var app: NotesVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(NotesVersion.init)
    }

    static func < (lhs: NotesVersion, rhs: NotesVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    var description: String { "\(major).\(minor)" }
}

/// The notes of one big update. They ship in the app: no network call.
struct WhatsNewEntry: Identifiable, Equatable {
    struct Highlight {
        let systemImage: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
    }

    let version: NotesVersion
    let highlights: [Highlight]
    let improvements: [LocalizedStringResource]

    var id: NotesVersion { version }

    static func == (lhs: WhatsNewEntry, rhs: WhatsNewEntry) -> Bool {
        lhs.version == rhs.version
    }
}

enum WhatsNewNotes {
    /// One entry for each big update, oldest first.
    static let entries: [WhatsNewEntry] = [
        WhatsNewEntry(
            version: NotesVersion(major: 1, minor: 1),
            highlights: [
                .init(
                    systemImage: "link",
                    title: "Send XMR as a link",
                    detail: "Whoever opens it claims the funds in Monero One. In Send, choose Link."
                ),
                .init(
                    systemImage: "at",
                    title: "Send to a name",
                    detail: "Enter an OpenAlias name in place of an address, checked with DNSSEC."
                ),
                .init(
                    systemImage: "key.fill",
                    title: "New seed phrase entry",
                    detail: "One box per word, paste a whole phrase at once, and a checksum check."
                ),
            ],
            improvements: [
                "Review shows the exact network fee you pay.",
                "Rounded QR codes.",
                "Fixes for custom node logins.",
                "General stability improvements and bug fixes.",
            ]
        ),
    ]

    /// The newest entry whose version is at or below `version`.
    static func newest(in entries: [WhatsNewEntry], atOrBelow version: NotesVersion?) -> WhatsNewEntry? {
        guard let version else { return nil }
        return entries.filter { $0.version <= version }.max { $0.version < $1.version }
    }
}

/// When the What's New banner shows. Per install, never per wallet.
///
/// UserDefaults holds two values: the last notes version the person saw,
/// and the date the banner first showed (with the version it showed for).
/// - A launch with no wallet files (a fresh install, or an install that never
///   made a wallet) counts the newest entry as seen, so it shows no banner.
/// - An update with wallets shows the banner until the X, the sheet, or 30
///   days after the banner first showed.
/// - A later entry (a newer big update) shows the banner again.
struct WhatsNewGate {
    static let lastSeenKey = "whatsNewLastSeenVersion"
    static let firstShownKey = "whatsNewBannerFirstShownAt"
    static let firstShownVersionKey = "whatsNewBannerFirstShownVersion"
    static let autoHideDays = 30

    private let defaults: UserDefaults
    private let entries: [WhatsNewEntry]
    private let appVersion: NotesVersion?

    init(
        defaults: UserDefaults = .standard,
        entries: [WhatsNewEntry] = WhatsNewNotes.entries,
        appVersion: NotesVersion? = .app
    ) {
        self.defaults = defaults
        self.entries = entries
        self.appVersion = appVersion
    }

    /// The notes for this build: the newest entry at or below its version.
    var newestEntry: WhatsNewEntry? {
        WhatsNewNotes.newest(in: entries, atOrBelow: appVersion)
    }

    var lastSeen: NotesVersion? {
        defaults.string(forKey: Self.lastSeenKey).flatMap(NotesVersion.init)
    }

    /// At every launch, before onboarding can create a wallet. With no
    /// wallet files, the newest entry counts as seen: a fresh install never
    /// sees a banner, and neither does a later update before any wallet.
    func launchCheck(hadWalletFiles: Bool) {
        guard !hadWalletFiles, let entry = newestEntry else { return }
        markSeen(entry)
    }

    /// The entry the banner offers now, or nil.
    func bannerEntry(now: Date) -> WhatsNewEntry? {
        guard let entry = newestEntry, !isSeen(entry), !isExpired(entry, now: now) else { return nil }
        return entry
    }

    /// The banner is on screen. The first time for an entry, store the date.
    func bannerShown(_ entry: WhatsNewEntry, now: Date) {
        guard firstShown(for: entry) == nil else { return }
        defaults.set(now, forKey: Self.firstShownKey)
        defaults.set(entry.version.description, forKey: Self.firstShownVersionKey)
    }

    /// The home appeared. A banner that first showed 30 or more days ago,
    /// with no tap on it or its X, goes for good.
    func homeAppeared(now: Date) {
        guard let entry = newestEntry, !isSeen(entry), isExpired(entry, now: now) else { return }
        markSeen(entry)
    }

    /// The X, or the sheet opened from the banner or from Settings.
    func markSeen(_ entry: WhatsNewEntry) {
        if lastSeen.map({ $0 < entry.version }) ?? true {
            defaults.set(entry.version.description, forKey: Self.lastSeenKey)
        }
        defaults.removeObject(forKey: Self.firstShownKey)
        defaults.removeObject(forKey: Self.firstShownVersionKey)
    }

    private func isSeen(_ entry: WhatsNewEntry) -> Bool {
        lastSeen.map { $0 >= entry.version } ?? false
    }

    /// The date the banner first showed for this entry. A date stored for
    /// an older entry does not count.
    private func firstShown(for entry: WhatsNewEntry) -> Date? {
        guard defaults.string(forKey: Self.firstShownVersionKey) == entry.version.description else { return nil }
        return defaults.object(forKey: Self.firstShownKey) as? Date
    }

    private func isExpired(_ entry: WhatsNewEntry, now: Date) -> Bool {
        guard let shown = firstShown(for: entry),
              let days = Calendar.current.dateComponents([.day], from: shown, to: now).day else { return false }
        return days >= Self.autoHideDays
    }
}

/// The What's New state the views read. One instance for the app.
@MainActor
final class WhatsNewModel: ObservableObject {
    static let shared = WhatsNewModel()

    /// The entry the home banner offers. While the sheet that the banner
    /// opened is up, it stays, so the banner leaves after the sheet closes.
    @Published private(set) var bannerEntry: WhatsNewEntry?

    private let gate: WhatsNewGate
    private let now: () -> Date

    init(gate: WhatsNewGate = WhatsNewGate(), now: @escaping () -> Date = Date.init) {
        self.gate = gate
        self.now = now
        bannerEntry = gate.bannerEntry(now: now())
    }

    /// The notes for this build, for Settings > Version.
    var newestEntry: WhatsNewEntry? { gate.newestEntry }

    /// At launch, before onboarding can create a wallet.
    func launchCheck(hadWalletFiles: Bool) {
        gate.launchCheck(hadWalletFiles: hadWalletFiles)
        refresh()
    }

    func homeAppeared() {
        gate.homeAppeared(now: now())
        refresh()
    }

    func bannerShown(_ entry: WhatsNewEntry) {
        gate.bannerShown(entry, now: now())
    }

    /// A tap on the banner. The banner stays until the sheet closes.
    func openFromBanner(_ entry: WhatsNewEntry) {
        gate.markSeen(entry)
    }

    /// Settings > Version. Returns the entry for the sheet.
    func openFromSettings() -> WhatsNewEntry? {
        guard let entry = gate.newestEntry else { return nil }
        gate.markSeen(entry)
        refresh()
        return entry
    }

    /// The X on the banner.
    func close(_ entry: WhatsNewEntry) {
        gate.markSeen(entry)
        withAnimation(.easeInOut) { refresh() }
    }

    func sheetClosed() {
        withAnimation(.easeInOut) { refresh() }
    }

    private func refresh() {
        let entry = gate.bannerEntry(now: now())
        if entry != bannerEntry { bannerEntry = entry }
    }
}
