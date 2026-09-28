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
    /// Bumped by every new text, so a late result is ignored.
    private var generation = 0
    private var work: Task<Void, Never>?
    /// The text of the last change. The field's binding and the flow's
    /// onChange can both report one keystroke.
    private var lastText: String?

    init(resolver: OpenAliasResolver = OpenAliasResolver(),
         pins: OpenAliasPinStore = OpenAliasPinStore(),
         typingDelay: Duration = OpenAliasResolver.Config.typingDelay,
         announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.resolver = resolver
        self.pins = pins
        self.typingDelay = typingDelay
        self.announce = announce
    }

    /// The result, when the lookup for the current name resolved.
    var summary: OpenAliasSummary? {
        guard let name, case .resolved(let result, let pin) = phase else { return nil }
        return OpenAliasSummary(name: name, address: result.address, dnssec: result.dnssec, pin: pin)
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
            setPhase(.resolved(found, pin))
            announce(String(localized: "Address found for \(name.display)") + ". " + found.dnssec.text)
        case .failure(let failure):
            setPhase(.failed(failure))
            announce(failure.message)
        }
    }

    private func setPhase(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        withAnimation(.easeOut(duration: OpenAliasResolver.Config.fade)) {
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

/// The lock icon and the DNSSEC word.
struct DnssecLine: View {
    let status: DnssecStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status == .valid ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(status == .valid ? Color.secondary : Color.yellow)
                .accessibilityHidden(true)
            Text(status.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The row under the recipient field on the name path. It takes the place
/// of the "Valid address" row.
struct OpenAliasStatusRow: View {
    @ObservedObject var lookup: OpenAliasLookupModel

    var body: some View {
        switch lookup.phase {
        case .idle, .pendingAddress, .address, .waiting, .pendingRejection:
            // The address step draws the address row itself.
            EmptyView()

        case .looking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Looking up \(lookup.name?.display ?? "")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)

        case .resolved(let result, _):
            DnssecLine(status: result.dnssec)
                .transition(.opacity)

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
                            .foregroundStyle(.orange)
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

/// The resolved address under the row: all of its characters, and the pin.
struct OpenAliasResultBlock: View {
    let summary: OpenAliasSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Wraps at any character, with no hyphen, and copies exactly the address.
            CodeText(summary.address, color: .label, selectable: true)
            switch summary.pin {
            case .none:
                EmptyView()
            case .same:
                Text("Same address as your last payment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .changed:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Address changed since your last payment")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
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
