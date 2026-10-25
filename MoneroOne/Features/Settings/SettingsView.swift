import MessageUI
import SwiftUI

enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var displayName: String {
        switch self {
        case .system: return String(localized: "System", comment: "Appearance setting: follow the system")
        case .light: return String(localized: "Light", comment: "Appearance setting")
        case .dark: return String(localized: "Dark", comment: "Appearance setting")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A Settings row that opens a page of its own.
enum SettingsPage: Hashable {
    case backup, exportViewKey, security, language, widget, currency, priceAlerts, sync, donate
}

struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceAlertService: PriceAlertService
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage(WalletManager.rotateReceiveAddressKey) private var rotateReceiveAddress: Bool = true
    @State private var showBackup = false
    @State private var showSecurity = false
    @State private var showDeleteConfirmation = false
    @State private var showResetSyncConfirmation = false
    @State private var showDiagnosticShare = false
    @State private var showMailComposer = false
    @State private var showNoMailApp = false
    /// The What's New sheet that the Version row opens.
    @State private var whatsNewEntry: WhatsNewEntry?
    /// The Language row's value; nil for System.
    @State private var languageChoice = AppLanguageSetting.standard.choice

    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The page in the right column on regular width. Security: the first
    /// page that asks for no PIN and shows no key, so opening Settings
    /// never puts a secret or a PIN field on screen.
    @State private var splitPage: SettingsPage? = .security

    /// iPad and the open iPhone Duo: the list beside the open page, as in
    /// iPad Settings. iPhone and the Duo cover push each page.
    private var isSplit: Bool { horizontalSizeClass == .regular }

    /// Apple Mail's composer when it has an account, else the default
    /// mail app, else one dialog with the address.
    private func contactSupport() {
        let mailto = SupportMail.mailtoURL(body: SupportMail.currentBody)
        let canOpenMailto = mailto.map { UIApplication.shared.canOpenURL($0) } ?? false
        switch SupportMail.route(
            canSendMail: MFMailComposeViewController.canSendMail(),
            canOpenMailto: canOpenMailto
        ) {
        case .composer:
            showMailComposer = true
        case .mailApp:
            guard let mailto else { return }
            openURL(mailto) { opened in
                if !opened { showNoMailApp = true }
            }
        case .noMailApp:
            showNoMailApp = true
        }
    }

    private var syncStatusText: String {
        switch walletManager.syncState {
        case .synced: return String(localized: "Synced", comment: "Wallet sync status")
        case .syncing(let progress, _): return "\(Int(progress))%"
        case .connecting: return String(localized: "Connecting", comment: "Wallet sync status")
        case .error: return String(localized: "Error", comment: "Wallet sync status")
        case .idle: return String(localized: "Idle", comment: "Wallet sync status")
        }
    }

    /// Names the wallet: the reset clears only the active one, and with
    /// its cache the transaction keys that no rescan brings back.
    private var resetSyncMessage: Text {
        if let name = walletManager.activeWallet?.name {
            return Text("“\(name)” scans again from its restore height. Transaction keys for its past sends are deleted.")
        }
        return Text("This wallet scans again from its restore height. Transaction keys for its past sends are deleted.")
    }

    var body: some View {
        if isSplit {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                settingsList
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
            } detail: {
                NavigationStack {
                    if let splitPage {
                        destination(splitPage)
                    }
                }
                // A new page starts at its root. A new wallet rebuilds the
                // page, so Backup and View Key never show the last one's.
                .id("\(splitPage.map { "\($0)" } ?? "")-\(walletManager.activeWallet?.id.uuidString ?? "")")
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                settingsList
            }
        }
    }

    /// A row that opens a page: in the right column on regular width,
    /// pushed on iPhone. On regular width the open page's row gets the
    /// brand tint inside its card, as the Activity split's rows do (List
    /// selection drew a solid orange capsule with a white title).
    @ViewBuilder
    private func pageLink<Label: View>(_ page: SettingsPage, @ViewBuilder label: () -> Label) -> some View {
        if isSplit {
            let isSelected = splitPage == page
            Button {
                splitPage = page
            } label: {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .listRowBackground(
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.brand.opacity(isSelected ? 0.15 : 0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            )
        } else {
            NavigationLink(destination: { destination(page) }, label: label)
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .backup:
            BackupView()
        case .exportViewKey:
            ExportViewKeyView()
        case .security:
            SecurityView()
        case .language:
            LanguageSettingsView(choice: $languageChoice)
        case .widget:
            WidgetSettingsView()
        case .currency:
            CurrencySettingsView(priceService: priceService)
        case .priceAlerts:
            PriceAlertsView(
                priceAlertService: priceAlertService,
                priceService: priceService
            )
        case .sync:
            SyncSettingsView()
        case .donate:
            DonationView()
        }
    }

    private var settingsList: some View {
        List {
            listSections
                // The split's list column draws rows on the sidebar's gray
                // material; white cards on the grouped gray, as on iPhone.
                .listRowBackground(isSplit ? Color(.secondarySystemGroupedBackground) : nil)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(isSplit ? .hidden : .automatic)
        .background(isSplit ? Color(.systemGroupedBackground) : .clear)
        .navigationTitle("Settings")
        .alert("Reset Sync Data?", isPresented: $showResetSyncConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                walletManager.resetSyncData()
            }
        } message: {
            resetSyncMessage
        }
        .alert("Remove All Wallets from Device?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove All", role: .destructive) {
                walletManager.deleteAllWallets()
            }
        } message: {
            if EnvelopeStore.shared.hasUnsettledSentLinks {
                Text("You can restore them only with their seed phrases or keys.\nUnclaimed payment links will be lost.")
            } else {
                Text("You can restore them only with their seed phrases or keys.")
            }
        }
    }

    @ViewBuilder
    private var listSections: some View {
        // Wallet Section
        Section {
            if !walletManager.isViewOnly {
                pageLink(.backup) {
                    SettingsRow(
                        icon: "key.fill",
                        title: "Backup Seed Phrase",
                        color: .brand
                    )
                }
                .accessibilityIdentifier("settings.backupRow")
            }

            pageLink(.exportViewKey) {
                SettingsRow(
                    icon: "eye.fill",
                    title: "Export View Key",
                    color: .purple
                )
            }
            .accessibilityIdentifier("settings.exportViewKeyRow")
        } header: {
            if let wallet = walletManager.activeWallet {
                Text(verbatim: "\(wallet.emoji) \(wallet.name)")
                    .textCase(nil)
                    .accessibilityLabel("Wallet: \(wallet.name)")
            } else {
                Text("Wallet")
            }
        }

        Section {
            pageLink(.security) {
                SettingsRow(
                    icon: "lock.shield",
                    title: "Security",
                    color: .blue
                )
            }
            .accessibilityIdentifier("settings.securityRow")

            Toggle(isOn: $rotateReceiveAddress) {
                SettingsRow(
                    icon: "qrcode",
                    title: "Fresh Receive Address",
                    color: .cyan
                )
            }
            .accessibilityIdentifier("settings.rotateReceiveAddressToggle")
            .onChange(of: rotateReceiveAddress) {
                walletManager.reconcileReceiveAddress()
            }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text("After a payment arrives, Receive shows a new address. Old ones keep working.")
        }

        // Display Section
        Section {
            Picker(selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            } label: {
                SettingsRow(
                    icon: "circle.lefthalf.filled",
                    title: "Appearance",
                    color: .indigo
                )
            }

            pageLink(.language) {
                HStack {
                    SettingsRow(
                        icon: "globe",
                        title: "Language",
                        color: .blue
                    )
                    Spacer()
                    Text((languageChoice ?? AppLanguageSetting.current).spokenName)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("settings.languageRow")

            pageLink(.widget) {
                SettingsRow(
                    icon: "square.stack.3d.up.fill",
                    title: "Home Screen Widget",
                    color: .blue
                )
            }
        } header: {
            Text("Display")
        }

        // Currency Section
        Section {
            pageLink(.currency) {
                HStack {
                    SettingsRow(
                        icon: "dollarsign.circle",
                        title: "Currency",
                        color: .green
                    )
                    Spacer()
                    Text(priceService.selectedCurrency.uppercased())
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Currency, \(priceService.selectedCurrency.uppercased())")
                .accessibilityHint("Change display currency")
            }

            Toggle(isOn: $priceService.showFiatFirst) {
                SettingsRow(
                    icon: "banknote",
                    title: "Show \(priceService.selectedCurrency.uppercased()) First",
                    color: .green
                )
            }
            .accessibilityIdentifier("settings.fiatModeToggle")

            pageLink(.priceAlerts) {
                HStack {
                    SettingsRow(
                        icon: "bell.badge",
                        title: "Price Alerts",
                        color: .pink
                    )
                    Spacer()
                    if !priceAlertService.alerts.isEmpty {
                        Text("\(priceAlertService.alerts.filter { $0.isEnabled }.count)")
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Price Alerts, \(priceAlertService.alerts.filter { $0.isEnabled }.count) active")
                .accessibilityHint("View and manage price alerts")
            }
        } header: {
            Text("Currency")
        }

        // Sync Section
        Section("Sync") {
            pageLink(.sync) {
                HStack {
                    SettingsRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Sync Settings",
                        color: .brand
                    )
                    Spacer()
                    Text(syncStatusText)
                        .foregroundColor(.secondary)
                        // Keeps its width so the title wraps
                        // instead: squeezed, "Синхронизировано"
                        // broke with a hyphen.
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sync Settings, status \(syncStatusText)")
            }
            .accessibilityIdentifier("settings.syncRow")
        }

        // Troubleshooting
        Section("Troubleshooting") {
            Button {
                contactSupport()
            } label: {
                SettingsRow(
                    icon: "envelope.fill",
                    title: "Contact Support",
                    color: .blue
                )
            }
            .accessibilityHint("Opens a mail to support with the app version and iPhone model")
            .accessibilityIdentifier("settings.contactSupportRow")
            .sheet(isPresented: $showMailComposer) {
                MailComposeView(body: SupportMail.currentBody)
                    .ignoresSafeArea()
            }
            .confirmationDialog("No Mail App", isPresented: $showNoMailApp, titleVisibility: .visible) {
                Button("Copy Address") {
                    UIPasteboard.general.string = SupportMail.address
                    HapticFeedback.shared.softTick()
                }
            } message: {
                Text("Write to support@monero.one with version \(SupportMail.appVersion).")
            }

            Button {
                showDiagnosticShare = true
            } label: {
                SettingsRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Share Diagnostic Log",
                    color: .purple
                )
            }
            .sheet(isPresented: $showDiagnosticShare) {
                // Prefer a .txt attachment; fall back to inline text
                // if the temp file can't be written.
                let items: [Any] = DiagnosticLog.shared.exportFile().map { [$0] }
                    ?? [DiagnosticLog.shared.export()]
                ShareSheet(items: items)
            }
        }

        // About Section
        Section("About") {
            // Opens this version's What's New notes, like Apple's
            // Settings > General > About > iOS Version.
            Button {
                whatsNewEntry = WhatsNewModel.shared.openFromSettings()
            } label: {
                HStack {
                    SettingsRow(
                        icon: "info.circle",
                        title: "Version",
                        color: .gray
                    )
                    // Colors, not hierarchical styles: in a List
                    // button those take the brand tint.
                    .foregroundStyle(Color.primary)
                    Spacer()
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                        .foregroundColor(.secondary)
                    if WhatsNewModel.shared.newestEntry != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"), build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
            }
            .disabled(WhatsNewModel.shared.newestEntry == nil)
            .accessibilityIdentifier("settings.versionRow")
            .sheet(item: $whatsNewEntry) { entry in
                WhatsNewSheet(entry: entry)
            }

            Link(destination: URL(string: "https://monero.one")!) {
                SettingsRow(
                    icon: "globe",
                    title: "Website",
                    color: .brand
                )
            }
            .accessibilityHint("Opens monero.one in your browser")

            Link(destination: URL(string: "https://monero.one/privacy")!) {
                SettingsRow(
                    icon: "hand.raised.fill",
                    title: "Privacy Policy",
                    color: .blue
                )
            }
            .accessibilityHint("Opens privacy policy in your browser")

            Link(destination: URL(string: "https://monero.one/terms")!) {
                SettingsRow(
                    icon: "doc.text.fill",
                    title: "Terms of Service",
                    color: .gray
                )
            }
            .accessibilityHint("Opens terms of service in your browser")
        }

        // Support the Developer Section
        Section("Support the Developer") {
            pageLink(.donate) {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.body)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.pink, .brand, .yellow],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)

                    Text("Donate XMR")
                        .foregroundColor(.brand)
                        .fontWeight(.medium)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Donate XMR")
                .accessibilityHint("Support the developer with a Monero donation")
            }

            Link(destination: URL(string: "https://apps.apple.com/app/id6757898541?action=write-review")!) {
                SettingsRow(
                    icon: "star.fill",
                    title: "Rate Monero One",
                    color: .brand
                )
            }
            .accessibilityHint("Opens the App Store to write a review")
            // The person rated here: the app never asks for Apple's
            // review prompt after a send.
            .environment(\.openURL, OpenURLAction { _ in
                ReviewPromptGate().ratedFromSettings()
                return .systemAction
            })
        }

        // Danger Zone
        Section {
            Button(role: .destructive) {
                showResetSyncConfirmation = true
            } label: {
                SettingsRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset Sync Data",
                    color: .brand
                )
            }
            .accessibilityHint("Scans this wallet again from its restore height")

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                SettingsRow(
                    icon: "trash",
                    title: "Remove All Wallets from Device",
                    color: .red
                )
            }
            .accessibilityHint("Removes every wallet from this device. Recovery with seed phrase is still possible.")
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: LocalizedStringResource
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .cornerRadius(6)

            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

/// The mail behind Contact Support. The body names the app version, the
/// iOS version and the model code, so support knows the build and the
/// phone. It holds no wallet, node or address data.
enum SupportMail {
    static let address = "support@monero.one"
    /// English in every language, so support can filter on it.
    static let subject = "Monero One iOS - Feedback"

    enum Route: Equatable {
        /// Apple Mail has an account: the system composer.
        case composer
        /// The default mail app, through a mailto: link.
        case mailApp
        /// No app opens mailto: one dialog with the address.
        case noMailApp
    }

    static func route(canSendMail: Bool, canOpenMailto: Bool) -> Route {
        if canSendMail { return .composer }
        return canOpenMailto ? .mailApp : .noMailApp
    }

    /// Two empty lines to write in, then the facts (as on Android).
    static func body(
        version: String, build: String, systemName: String, systemVersion: String, model: String
    ) -> String {
        [
            "", "", "----------",
            "Monero One \(version) (\(build))",
            "\(systemName) \(systemVersion)",
            model
        ].joined(separator: "\n")
    }

    static func mailtoURL(body: String) -> URL? {
        // urlQueryAllowed keeps & = + ? #, which would end a value early.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "subject", value: encode(subject)),
            URLQueryItem(name: "body", value: encode(body))
        ]
        return components.url
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// "1.1.0 (11)"
    static var appVersion: String { "\(version) (\(build))" }

    /// The model code ("iPhone18,1"), as in the diagnostic log.
    static var modelCode: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    @MainActor static var currentBody: String {
        body(
            version: version,
            build: build,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            model: modelCode
        )
    }
}

/// The system mail composer, filled in with the support mail.
struct MailComposeView: UIViewControllerRepresentable {
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([SupportMail.address])
        composer.setSubject(SupportMail.subject)
        composer.setMessageBody(body, isHTML: false)
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
