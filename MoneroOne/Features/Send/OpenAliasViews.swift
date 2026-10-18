import Accessibility
import MoneroKit
import SwiftUI

// OpenAlias names in the Send flow (OpenAlias send spec, section 5): the
// lookup model, and the rows that the address and review steps show.

/// What the flow keeps after Continue on a resolved name.
struct OpenAliasSummary: Equatable {
    let name: OpenAliasName
    let address: String
    let dnssec: DnssecStatus
    let pin: PinState
    /// The sanitized `recipient_name` of the record.
    var recipientName: String? = nil
    /// The sanitized `tx_description` of the record.
    var txDescription: String? = nil
}

extension OpenAliasSummary {
    /// Monero One's own names show the Monero One logo, but only on a
    /// DNSSEC-valid answer: an unsigned answer can be forged on the way, and
    /// the logo must not vouch for its address (founder, 2026-10-01). The
    /// name decides, never the record: a record that calls itself "Monero
    /// One" gets a monogram. The card and the review step both read this.
    var showsMoneroOneLogo: Bool {
        dnssec == .valid && OpenAlias.isOperatorName(name.display)
    }

    var initials: String? {
        OpenAlias.initials(recipientName: recipientName, display: name.display)
    }

    /// VoiceOver: the record name and the OpenAlias name.
    var spokenName: String {
        guard let recipientName else { return name.display }
        return String(localized: "\(recipientName), \(name.display)")
    }

    var pinText: String? {
        switch pin {
        case .none: return nil
        case .same: return String(localized: "Same address as your last payment")
        case .changed: return String(localized: "Address changed since your last payment")
        }
    }

    /// VoiceOver value of the recipient card: the DNSSEC word and the pin.
    var spokenStatus: String {
        [dnssec.text, pinText].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Lookup model

/// The row under the recipient field: when it shows, and the lookup for a
/// name. It lives with the Send flow, so a result survives a step back
/// from the amount step.
@MainActor
final class OpenAliasLookupModel: ObservableObject {
    enum Rejection: Equatable {
        case invalidName
        case reserved
    }

    /// Typed text is classified only after the typing delay, so no red row
    /// flashes before the "@" or "." arrives. Pasted, scanned and returned
    /// text is classified at once.
    enum Phase: Equatable {
        /// An empty field.
        case idle
        /// Typed text that is an address, inside the typing delay. Nothing shows yet.
        case pendingAddress
        /// An address: the existing "Valid address" or "Invalid address" row shows.
        case address
        /// A name, inside the typing delay.
        case waiting
        case looking
        case resolved(OpenAliasResult, PinState)
        case failed(OpenAliasFailure)
        /// A text that is no name, inside the typing delay. Nothing shows yet.
        case pendingRejection(Rejection)
        case rejected(Rejection)
    }

    @Published private(set) var phase: Phase = .idle
    /// The name of the current lookup. Nil when the field holds no name.
    @Published private(set) var name: OpenAliasName?
    /// The network of the wallet. The flow sets it before the first lookup.
    var network: NetworkType = .mainnet

    private let resolver: OpenAliasResolver
    private let pins: OpenAliasPinStore
    private let typingDelay: Duration
    private let announce: @MainActor (String) -> Void
    /// Plays when a lookup resolves.
    private let resolvedFeedback: @MainActor () -> Void
    /// Bumped by every new text, so a late result is ignored.
    private var generation = 0
    private var work: Task<Void, Never>?
    /// The text of the last change. The field's binding and the flow's
    /// onChange can both report one keystroke.
    private var lastText: String?

    init(resolver: OpenAliasResolver = OpenAliasResolver(),
         pins: OpenAliasPinStore = OpenAliasPinStore(),
         typingDelay: Duration = OpenAliasResolver.Config.typingDelay,
         announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
         resolvedFeedback: @escaping @MainActor () -> Void = { HapticFeedback.shared.softTick() }) {
        self.resolver = resolver
        self.pins = pins
        self.typingDelay = typingDelay
        self.announce = announce
        self.resolvedFeedback = resolvedFeedback
    }

    /// The result, when the lookup for the current name resolved.
    var summary: OpenAliasSummary? {
        guard let name, case .resolved(let result, let pin) = phase else { return nil }
        return OpenAliasSummary(name: name, address: result.address, dnssec: result.dnssec, pin: pin,
                                recipientName: result.recipientName, txDescription: result.txDescription)
    }

    var isLooking: Bool { phase == .looking }

    /// Typing: the text is classified, and a lookup starts, after the
    /// typing delay.
    func textChanged(_ text: String) {
        update(text, immediate: false)
    }

    /// Paste, Scan and Return: the text is classified, and a lookup starts,
    /// at once. A name whose lookup failed is looked up again.
    func submit(_ text: String) {
        update(text, immediate: true)
    }

    /// Try Again, after a timeout, network or Tor error.
    func retry() {
        guard let name, case .failed(let failure) = phase, failure.isRetryable else { return }
        startLookup(name)
    }

    /// Stops the lookup in progress and ignores its result.
    func cancel() {
        stopWork()
        switch phase {
        case .waiting, .looking, .pendingAddress, .pendingRejection:
            name = nil
            phase = .idle
        default:
            break
        }
    }

    /// Writes the pin when a send to a resolved name succeeded (spec 4.6).
    @discardableResult
    func recordPinIfSent(phase flowPhase: SendFlowPhase, summary: OpenAliasSummary?, sentAddress: String) -> Bool {
        guard case .success = flowPhase, let summary, summary.address == sentAddress else { return false }
        pins.record(query: summary.name.query, address: sentAddress, network: network)
        return true
    }

    /// The address check of spec 4.4: this network first, then the other one.
    static func check(_ address: String, network: NetworkType) -> AddressCheck {
        if MoneroWallet.isValidAddress(address, networkType: network) { return .valid }
        let other: NetworkType = network == .mainnet ? .testnet : .mainnet
        return MoneroWallet.isValidAddress(address, networkType: other) ? .otherNetwork : .invalid
    }

    // MARK: Private

    private func update(_ text: String, immediate: Bool) {
        if !immediate, text == lastText { return }
        lastText = text
        switch OpenAlias.classify(text) {
        case .empty:
            stopWork()
            name = nil
            setPhase(.idle)

        case .address:
            stopWork()
            name = nil
            if immediate {
                setPhase(.address)
            } else {
                // The row waits for the typing delay, also when one is on
                // screen: it judged the text before this change.
                setPhase(.pendingAddress)
                schedule { [weak self] in self?.setPhase(.address) }
            }

        case .name(let newName):
            if let name, name.query == newName.query {
                // The same query name: keep the state, show the new text.
                if name != newName { self.name = newName }
                switch phase {
                case .waiting:
                    if immediate {
                        startLookup(newName)
                    } else {
                        // Still typing (a trailing dot, for example): the
                        // delay starts again.
                        stopWork()
                        schedule { [weak self] in self?.startLookup(newName) }
                    }
                case .failed where immediate:
                    // Return or Paste after a failed lookup: look it up again.
                    startLookup(newName)
                default:
                    break
                }
                return
            }
            stopWork()
            name = newName
            if immediate {
                startLookup(newName)
            } else {
                setPhase(.waiting)
                schedule { [weak self] in self?.startLookup(newName) }
            }

        case .reserved:
            reject(.reserved, immediate: immediate)
        case .invalidName:
            reject(.invalidName, immediate: immediate)
        }
    }

    private func reject(_ rejection: Rejection, immediate: Bool) {
        name = nil
        stopWork()
        // A red row already on screen changes in place. A new one waits
        // for the typing delay.
        if case .rejected = phase {
            setPhase(.rejected(rejection))
        } else if immediate {
            setPhase(.rejected(rejection))
        } else {
            setPhase(.pendingRejection(rejection))
            schedule { [weak self] in self?.setPhase(.rejected(rejection)) }
        }
    }

    /// Stops the scheduled step or the lookup in progress. A late result
    /// is ignored.
    private func stopWork() {
        generation += 1
        work?.cancel()
        work = nil
    }

    /// Runs `action` after the typing delay, unless new text comes first.
    private func schedule(_ action: @escaping @MainActor () -> Void) {
        let expected = generation
        let delay = typingDelay
        work = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            action()
        }
    }

    private func startLookup(_ lookupName: OpenAliasName) {
        stopWork()
        let expected = generation
        setPhase(.looking)
        let resolver = self.resolver
        let network = self.network
        work = Task { [weak self] in
            let result = await resolver.resolve(lookupName) { address in
                OpenAliasLookupModel.check(address, network: network)
            }
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.finish(result)
        }
    }

    private func finish(_ result: Result<OpenAliasResult, OpenAliasFailure>) {
        work = nil
        guard let name else { return }
        switch result {
        case .success(let found):
            let pin = pins.state(query: name.query, address: found.address, network: network)
            // The field turns into the recipient card with the step-forward
            // spring: short, with no visible bounce.
            setPhase(.resolved(found, pin), animation: .spring(response: 0.3, dampingFraction: 0.85))
            resolvedFeedback()
            announce(String(localized: "Address found for \(name.display)") + ". " + found.dnssec.text)
        case .failure(let failure):
            setPhase(.failed(failure))
            announce(failure.message)
        }
    }

    private func setPhase(_ newPhase: Phase,
                          animation: Animation = .easeOut(duration: OpenAliasResolver.Config.fade)) {
        guard newPhase != phase else { return }
        withAnimation(animation) {
            phase = newPhase
        }
    }
}

// MARK: - Texts

extension OpenAliasFailure {
    var message: String {
        switch self {
        case .noRecord: return String(localized: "No Monero address for this name")
        case .severalAddresses: return String(localized: "This name lists more than one Monero address")
        case .paymentID: return String(localized: "This name uses a payment ID, which Monero no longer supports. Ask the recipient for a subaddress or an integrated address.")
        case .invalidAddress: return String(localized: "The record holds an invalid Monero address")
        case .wrongNetwork: return String(localized: "The record holds an address for another network")
        case .dnssecFailed: return String(localized: "DNSSEC check failed. Someone may have changed this answer.")
        case .timeout: return String(localized: "The lookup took too long")
        case .network: return String(localized: "Can't reach the name service")
        case .tor: return String(localized: "Can't reach the name service through Tor")
        }
    }

    /// Timeout, network and Tor errors get a Try Again button.
    var isRetryable: Bool {
        switch self {
        case .timeout, .network, .tor: return true
        default: return false
        }
    }
}

extension OpenAliasLookupModel.Rejection {
    var message: String {
        switch self {
        case .invalidName: return String(localized: "Invalid name")
        case .reserved: return String(localized: "Monero One names come in a later update")
        }
    }
}

extension DnssecStatus {
    var text: String {
        switch self {
        case .valid: return String(localized: "DNSSEC valid")
        case .off: return String(localized: "DNSSEC off")
        }
    }
}

// MARK: - Views

/// The lock icon and the DNSSEC word. Valid is quiet: a secondary lock and
/// text, never green and never "Verified" (D5). Off is a caution: a yellow
/// open lock, with the text in the label color.
struct DnssecLine: View {
    let status: DnssecStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status == .valid ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(status == .valid ? Color.secondary : Color.yellow)
                .accessibilityHidden(true)
            Text(status.text)
                .foregroundStyle(status == .valid ? Color.secondary : Color.primary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// The row under the recipient field on the name path, in place of the
/// "Valid address" row: a failed lookup or a rejected name. While a lookup
/// runs, the spinner sits in the field. A resolved name turns the field
/// into `OpenAliasRecipientCard`, with `OpenAliasResolvedLines` here.
struct OpenAliasStatusRow: View {
    @ObservedObject var lookup: OpenAliasLookupModel

    var body: some View {
        switch lookup.phase {
        case .idle, .pendingAddress, .address, .waiting, .pendingRejection, .looking, .resolved:
            EmptyView()

        case .failed(let failure):
            HStack(spacing: 8) {
                errorLabel(failure.message)
                if failure.isRetryable {
                    Spacer(minLength: 0)
                    Button {
                        lookup.retry()
                    } label: {
                        Text("Try Again")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.brand)
                    }
                    .accessibilityHint("Look up the name again")
                }
            }
            .transition(.opacity)

        case .rejected(let rejection):
            errorLabel(rejection.message)
                .transition(.opacity)
        }
    }

    /// In the style of the "Invalid address" row.
    private func errorLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Contacts-style monogram: up to two initials on a gray disc, or a
/// person glyph when no letter is left. The app never fetches an image or
/// a favicon for a name: that request would show the user's IP address to
/// the domain.
struct RecipientMonogram: View {
    let initials: String?
    var diameter: CGFloat = 44

    var body: some View {
        Circle()
            .fill(Color.gray.gradient)
            .frame(width: diameter, height: diameter)
            .overlay {
                Group {
                    if let initials {
                        Text(verbatim: initials)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    } else {
                        Image(systemName: "person.fill")
                    }
                }
                // A fixed size: the disc does not grow with Dynamic Type.
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .padding(diameter * 0.12)
            }
            .accessibilityHidden(true)
    }
}

/// The picture of a recipient: the Monero One logo for Monero One's own
/// names on a DNSSEC-valid answer (`showsMoneroOneLogo`), else the monogram.
struct RecipientAvatar: View {
    let summary: OpenAliasSummary
    var diameter: CGFloat = 44

    var body: some View {
        if summary.showsMoneroOneLogo {
            MoneroOneAvatar(diameter: diameter)
        } else {
            RecipientMonogram(initials: summary.initials, diameter: diameter)
        }
    }
}

/// The logo of Welcome and Unlock, still, clipped to the circle the same
/// way. It comes from the app bundle: nothing is fetched.
struct MoneroOneAvatar: View {
    var diameter: CGFloat = 44

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(colorScheme == .dark ? "MoneroSymbolDark" : "MoneroSymbol")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: diameter, height: diameter)
            .scaleEffect(1.15)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

/// The field after a lookup resolved: the recipient, the way Mail turns an
/// address into a contact and Apple Pay names the merchant. The record name
/// is the title and the OpenAlias name the subtitle. Without a record name,
/// the OpenAlias name is the title and the short address the subtitle. The
/// address step draws the field background around it.
struct OpenAliasRecipientCard: View {
    let summary: OpenAliasSummary
    let onClear: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Large text: the names get the full width, under the monogram.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        RecipientAvatar(summary: summary)
                        Spacer(minLength: 8)
                        clearButton
                    }
                    names
                }
            } else {
                HStack(spacing: 12) {
                    RecipientAvatar(summary: summary)
                    names
                    Spacer(minLength: 0)
                    clearButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element: the names, the DNSSEC state, and Clear as an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary.spokenName))
        .accessibilityValue(Text(verbatim: summary.spokenStatus))
        .accessibilityAction(named: Text("Clear address"), onClear)
        .accessibilityIdentifier("send.recipientCard")
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let recipientName = summary.recipientName {
                Text(verbatim: recipientName)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                OpenAliasNameText(name: summary.name.display)
            } else {
                OpenAliasNameText(name: summary.name.display, style: .headline, weight: .semibold, color: .label)
                Text(verbatim: ReceiveAddressLogic.shortAddress(summary.address))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clearButton: some View {
        Button(action: onClear) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                // A 44 pt target around the glyph, which keeps its place.
                .padding(12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-12)
        .accessibilityLabel("Clear address")
    }
}

/// An OpenAlias name, every character of it, with no hyphen added:
/// "donate@get-monero.org" reads as another domain, and a cut-off name can
/// hide the end of its domain. A long name wraps after the "@" or before a
/// "." first, and between two characters only inside a longer part.
struct OpenAliasNameText: View {
    let name: String
    var style: UIFont.TextStyle = .subheadline
    var weight: UIFont.Weight = .regular
    var color: UIColor = .secondaryLabel

    var body: some View {
        CodeText(
            Self.wrappable(name),
            style: style,
            monospaced: false,
            weight: weight,
            color: color,
            lineBreakMode: .byWordWrapping
        )
    }

    /// The name with a zero-width space after the "@" and before each ".",
    /// the places where a line can break.
    static func wrappable(_ name: String) -> String {
        var text = ""
        for character in name {
            if character == "." { text.append("\u{200B}") }
            text.append(character)
            if character == "@" { text.append("\u{200B}") }
        }
        return text
    }
}

/// The quiet lines under the recipient card: the DNSSEC state, the short
/// address (when the card shows none), and the pin state. VoiceOver reads
/// them on the card.
struct OpenAliasResolvedLines: View {
    let summary: OpenAliasSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.recipientName != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        DnssecLine(status: summary.dnssec)
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                        address
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        DnssecLine(status: summary.dnssec)
                        address
                    }
                }
            } else {
                DnssecLine(status: summary.dnssec)
            }
            pinLine
        }
        .font(.caption)
        .accessibilityHidden(true)
    }

    private var address: some View {
        Text(verbatim: ReceiveAddressLogic.shortAddress(summary.address))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pinLine: some View {
        switch summary.pin {
        case .none:
            EmptyView()
        case .same:
            Text("Same address as your last payment")
                .foregroundStyle(.secondary)
        case .changed:
            // The amount step's caution style: a yellow triangle, the text
            // in the label color.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Address changed since your last payment")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The notes under the recipient row of the review step.
struct OpenAliasReviewNotes: View {
    let summary: OpenAliasSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DnssecLine(status: summary.dnssec)
            if summary.pin == .none {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("First payment to this name. Check the address with the recipient.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        // Both icons at the size of the caption text.
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The `tx_description` of the record, as a row of the review card. The
/// record's owner wrote it, like the name.
struct OpenAliasDescriptionRow: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                label
                Spacer(minLength: 0)
                Text(verbatim: text)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text("Description", comment: "Review: the payment description in the OpenAlias record of the recipient")
            .foregroundStyle(.secondary)
    }
}
