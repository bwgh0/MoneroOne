import SwiftUI

/// A language Monero One can show, named in that language.
struct AppLanguage: Identifiable, Equatable {
    /// The localization: "de", "pt-BR", "zh-Hans".
    let code: String
    /// The language's own name. Never translated.
    let name: String

    var id: String { code }

    /// English and the 15 translations, in the order the picker lists them.
    static let all: [AppLanguage] = [
        AppLanguage(code: "en", name: "English"),
        AppLanguage(code: "de", name: "Deutsch"),
        AppLanguage(code: "es", name: "Español"),
        AppLanguage(code: "fr", name: "Français"),
        AppLanguage(code: "it", name: "Italiano"),
        AppLanguage(code: "nl", name: "Nederlands"),
        AppLanguage(code: "pl", name: "Polski"),
        AppLanguage(code: "pt-BR", name: "Português (Brasil)"),
        AppLanguage(code: "ro", name: "Română"),
        AppLanguage(code: "tr", name: "Türkçe"),
        AppLanguage(code: "ru", name: "Русский"),
        AppLanguage(code: "uk", name: "Українська"),
        AppLanguage(code: "zh-Hans", name: "简体中文"),
        AppLanguage(code: "zh-Hant", name: "繁體中文"),
        AppLanguage(code: "ja", name: "日本語"),
        AppLanguage(code: "ko", name: "한국어"),
    ]

    /// The language a code stands for: exact ("pt-BR"), else with the
    /// region dropped ("de-CH" is Deutsch, "zh-Hans-US" is 简体中文), else
    /// by language alone ("zh" is the first Chinese).
    static func matching(_ code: String) -> AppLanguage? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        func find(_ candidate: String) -> AppLanguage? {
            all.first { $0.code.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        var parts = normalized.split(separator: "-").map(String.init)
        while !parts.isEmpty {
            if let match = find(parts.joined(separator: "-")) { return match }
            parts.removeLast()
        }
        let language = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return all.first {
            $0.code.split(separator: "-").first.map(String.init)?.caseInsensitiveCompare(language) == .orderedSame
        }
    }

    /// The language's name, marked with its language so VoiceOver reads it
    /// in that language's voice.
    var spokenName: AttributedString {
        var text = AttributedString(name)
        text.languageIdentifier = code
        return text
    }
}

/// Monero One's language choice. It is the `AppleLanguages` value iOS
/// writes for Settings › Apps › Monero One › Language, kept in the app's
/// own defaults, and iOS reads it when the app starts: a change shows the
/// next time Monero One opens.
struct AppLanguageSetting {
    let defaults: UserDefaults
    /// The name of the defaults domain above: the bundle id for the app's
    /// own defaults, the suite name in tests.
    let domainName: String

    static let key = "AppleLanguages"

    static var standard: AppLanguageSetting {
        AppLanguageSetting(defaults: .standard, domainName: Bundle.main.bundleIdentifier ?? "one.monero.MoneroOne")
    }

    /// The picked language; nil for System, which follows the phone. Read
    /// from the app's own domain only: the merged value falls back to the
    /// phone's language list and would never read as System.
    var choice: AppLanguage? {
        guard let codes = defaults.persistentDomain(forName: domainName)?[Self.key] as? [String],
              let first = codes.first else { return nil }
        return AppLanguage.matching(first)
    }

    /// Picks `language`, or System for nil.
    func set(_ language: AppLanguage?) {
        if let language {
            defaults.set([language.code], forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }

    /// The language the app shows right now.
    static var current: AppLanguage {
        Bundle.main.preferredLocalizations.first.flatMap(AppLanguage.matching) ?? AppLanguage.all[0]
    }
}

/// Settings › Display › Language: System (follow the phone), then English
/// and the 15 translations, each in its own name.
struct LanguageSettingsView: View {
    /// The Settings row's value; nil for System.
    @Binding var choice: AppLanguage?
    /// True once the user picks something here: the note then says when it
    /// takes effect.
    @State private var changed = false

    private let setting = AppLanguageSetting.standard

    var body: some View {
        List {
            Section {
                row(selected: choice == nil, action: { pick(nil) }) {
                    Text(String(localized: "System", comment: "Appearance setting: follow the system"))
                }
                .accessibilityIdentifier("language.system")
            } footer: {
                // Under the first row, where it shows without scrolling.
                Text(String(localized: "Monero One switches language the next time it opens.", comment: "Language settings: a new language shows after the app restarts"))
                    .fontWeight(changed ? .semibold : .regular)
            }

            Section {
                ForEach(AppLanguage.all) { language in
                    row(selected: choice == language, action: { pick(language) }) {
                        Text(language.spokenName)
                    }
                    .accessibilityIdentifier("language.\(language.code)")
                }
            }
        }
        .navigationTitle(String(localized: "Language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row<Label: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack {
                // Color.primary, not the hierarchical .primary: in a list
                // button that resolves to the orange tint.
                label()
                    .foregroundStyle(Color.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pick(_ language: AppLanguage?) {
        guard language != choice else { return }
        HapticFeedback.shared.softTick()
        setting.set(language)
        choice = language
        changed = true
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Monero One switches language the next time it opens.", comment: "Language settings: a new language shows after the app restarts")
        )
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsView(choice: .constant(AppLanguage.all[1]))
    }
}
