import SwiftUI
import MoneroKit

/// Settings > Payment Links: links this device sent and links it received.
struct PaymentLinksView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = EnvelopeStore.shared
    @StateObject private var checker = PaymentLinksStatusChecker()

    var body: some View {
        List {
            if store.records.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No payment links yet")
                            .font(.headline)
                        Text("In Send, tap Send with a link to make one.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .accessibilityElement(children: .combine)
                }
            }

            if !store.sent.isEmpty {
                Section {
                    ForEach(store.sent) { record in
                        NavigationLink {
                            PaymentLinkDetailView(recordId: record.id)
                        } label: {
                            PaymentLinkRow(record: record, display: PaymentLinkDisplay(record: record, walletManager: walletManager))
                        }
                    }
                } header: {
                    Text("Sent")
                } footer: {
                    if checker.isChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Checking links…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if !store.received.isEmpty {
                Section("Received") {
                    ForEach(store.received) { record in
                        Button {
                            PaymentLinksCoordinator.shared.present(record)
                        } label: {
                            PaymentLinkRow(record: record, display: PaymentLinkDisplay(record: record, walletManager: walletManager))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityHint(record.isDone ? "" : "Opens the link to claim it")
                        .swipeActions {
                            if record.isDone {
                                Button("Remove", role: .destructive) {
                                    store.remove(record)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Payment Links")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            PaymentLinksStatusChecker.reconcileFunding(store: store, walletManager: walletManager)
            PaymentLinksStatusChecker.forgetMinedClaimWords(store: store, walletManager: walletManager)
            checker.start(walletManager: walletManager, store: store)
        }
        .onDisappear { checker.stop() }
    }
}

// MARK: - Row

struct PaymentLinkRow: View {
    let record: EnvelopeRecord
    let display: PaymentLinkDisplay

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(display.tint.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: record.role == .sent ? "arrow.up.right" : "arrow.down.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(record.role == .sent ? Color.brand : Color.green)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))) XMR")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PaymentLinkStatusChip(display: display)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.role == .sent ? String(localized: "Sent") : String(localized: "Received")) \(XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))) XMR, \(record.createdAt.formatted(date: .abbreviated, time: .shortened)), \(display.label)")
    }
}

struct PaymentLinkStatusChip: View {
    let display: PaymentLinkDisplay

    var body: some View {
        Text(display.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(display.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(display.tint.opacity(0.15))
            .clipShape(Capsule())
    }
}

/// Label and colors for a record's status. Sent links that are not on chain
/// long enough read their confirmations from the active wallet's own
/// funding transaction, so the list stays current without opening the
/// envelope.
struct PaymentLinkDisplay {
    let status: EnvelopeStatus
    let isExpired: Bool
    let confirmations: Int?
    let role: EnvelopeRecord.Role
    let claimedHere: Bool

    @MainActor
    init(record: EnvelopeRecord, walletManager: WalletManager?, now: Date = Date()) {
        var status = record.status
        var confirmations = record.confirmations
        if record.role == .sent, status == .pending || status == .created,
           let walletManager,
           let txid = record.fundingTxid,
           let tx = walletManager.transactions.first(where: { $0.id == txid }),
           let txConfirmations = Self.confirmations(of: tx, daemonHeight: walletManager.daemonHeight) {
            confirmations = txConfirmations
            if status == .created { status = .pending }
        }
        self.status = status
        self.confirmations = confirmations
        self.role = record.role
        self.claimedHere = record.role == .received && record.settleTxid != nil
        self.isExpired = EnvelopeStatusRules.isExpired(status, expiry: record.expiry, now: now)
    }

    /// A history entry's confirmation count is frozen when the list is
    /// read; count from its block and the live daemon height instead.
    nonisolated static func confirmations(of tx: MoneroTransaction, daemonHeight: UInt64) -> Int? {
        if let height = tx.blockHeight, height > 0, daemonHeight > height {
            return Int(daemonHeight - height)
        }
        return tx.confirmations
    }

    var label: String {
        if isExpired { return String(localized: "Expired") }
        switch status {
        case .created, .notFunded:
            return role == .sent ? String(localized: "Not funded") : String(localized: "Not checked")
        case .pending:
            if let confirmations {
                return String(localized: "Pending \(min(confirmations, EnvelopeLink.confirmationsToUnlock))/\(EnvelopeLink.confirmationsToUnlock)")
            }
            return String(localized: "Pending")
        case .ready:
            return role == .sent ? String(localized: "Ready") : String(localized: "Ready to claim")
        case .claimed:
            if role == .received { return claimedHere ? String(localized: "Claimed") : String(localized: "Already claimed") }
            return String(localized: "Claimed")
        case .reclaimed:
            return String(localized: "Reclaimed")
        }
    }

    var tint: Color {
        if isExpired { return .yellow }
        switch status {
        case .created: return role == .sent ? .red : .gray
        case .notFunded: return role == .sent ? .red : .gray
        case .pending: return .brand
        case .ready: return .green
        case .claimed: return claimedHere || role == .sent ? .green : .gray
        case .reclaimed: return .gray
        }
    }

    var textColor: Color {
        // Yellow text is hard to read; a caution chip keeps the label color.
        isExpired ? .primary : tint
    }
}

// MARK: - Background status check

/// Opens each sent link that someone could have claimed since the last look,
/// one at a time, while Payment Links is on screen.
@MainActor
final class PaymentLinksStatusChecker: ObservableObject {
    @Published private(set) var isChecking = false
    private var task: Task<Void, Never>?

    func start(walletManager: WalletManager, store: EnvelopeStore) {
        guard task == nil else { return }
        // Pending links need no envelope: their confirmations come from the
        // active wallet. Only links that can have moved are opened.
        let now = Date()
        let candidates = store.sent.filter { record in
            guard record.link != nil else { return false }
            // One look per block is enough; a scan stops the active wallet.
            if let last = record.lastCheckedAt, now.timeIntervalSince(last) < Self.recheckInterval { return false }
            switch record.status {
            case .ready: return true
            case .reclaimed:
                // The reclaim reached this wallet: nothing left to watch.
                // Not seen here: look whether it dropped.
                guard let txid = record.settleTxid else { return false }
                return !walletManager.transactions.contains { $0.id == txid && $0.status != .failed }
            case .pending:
                let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
                return (display.confirmations ?? 0) >= EnvelopeLink.confirmationsToUnlock
            default: return false
            }
        }
        guard !candidates.isEmpty else { return }
        isChecking = true
        task = Task { [weak self] in
            var leased = false
            defer {
                if leased { EnvelopeRuntime.shared.release() }
                self?.isChecking = false
                self?.task = nil
            }
            do {
                try await EnvelopeRuntime.shared.acquire(walletManager)
                leased = true
            } catch {
                return
            }
            for candidate in candidates {
                guard !Task.isCancelled, let link = candidate.link,
                      var record = store.record(id: candidate.id, role: .sent) else { continue }
                let observation: EnvelopeObservation
                do {
                    observation = try await EnvelopeRuntime.shared.check(link: link, address: record.address)
                } catch {
                    DiagnosticLog.shared.log("Payment link check failed: \(error.localizedDescription)")
                    continue
                }
                let status = EnvelopeStatusRules.status(
                    for: observation,
                    reclaimTxid: record.settleTxid,
                    reclaimAge: record.settledAt.map { Date().timeIntervalSince($0) }
                )
                record.status = status
                record.lastBalance = observation.balance
                record.confirmations = observation.fundingConfirmations
                record.lastCheckedAt = Date()
                try? store.save(record)
                if status.isSettled {
                    await EnvelopeRuntime.shared.deleteFiles(id: record.id)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    static let recheckInterval: TimeInterval = 120

    /// A received link keeps its words until our claim is mined, so a claim
    /// that dropped can run again. Once the active wallet shows the claim
    /// confirmed, the words go.
    static func forgetMinedClaimWords(store: EnvelopeStore, walletManager: WalletManager) {
        for var record in store.received where record.status == .claimed && record.words != nil {
            guard let txid = record.settleTxid,
                  walletManager.transactions.contains(where: { $0.id == txid && $0.status == .confirmed }) else { continue }
            record.words = nil
            try? store.save(record)
        }
    }

    /// A sent record saved but not marked funded (the app quit during the
    /// broadcast, or the error came after the node took it): adopt a
    /// funding transaction the active wallet sent to the envelope address.
    static func reconcileFunding(store: EnvelopeStore, walletManager: WalletManager) {
        let activeId = walletManager.activeWallet?.id.uuidString
        for var record in store.sent where record.fundingTxid == nil && (record.status == .created || record.status == .notFunded) {
            // Only the wallet that funded it can hold the funding.
            if let walletId = record.walletId, walletId != activeId { continue }
            let funding = walletManager.transactions.first { tx in
                tx.type == .outgoing && tx.status != .failed && tx.destinations.contains { $0.address == record.address }
            }
            guard let funding else { continue }
            record.fundingTxid = funding.id
            record.status = .pending
            record.confirmations = funding.confirmations
            try? store.save(record)
        }
    }
}

// MARK: - Sent link detail

struct PaymentLinkDetailView: View {
    let recordId: String

    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var store = EnvelopeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirmation = false
    @State private var retrying = false
    @State private var retryError: String?
    @State private var hardwareIntent: HardwareSessionSheet.Intent?
    @State private var showRetryConfirmation = false
    @StateObject private var biometricAuth = BiometricAuthManager()
    /// Same setting as Send: re-authenticate before money leaves.
    @AppStorage("requireAuthForSend") private var requireAuthForSend = true

    private var record: EnvelopeRecord? { store.record(id: recordId, role: .sent) }

    /// A link funded from another wallet: only that wallet can see whether
    /// the funding went out, so only it may retry.
    private func fundedElsewhere(_ record: EnvelopeRecord) -> Bool {
        guard let walletId = record.walletId else { return false }
        return walletId != walletManager.activeWallet?.id.uuidString
    }

    private func fundingTotal(_ record: EnvelopeRecord) -> String {
        XMRFormatter.format(EnvelopeRuntime.xmr(record.amount + (record.feeReserve ?? 0)))
    }

    var body: some View {
        Group {
            if let record {
                content(record)
            } else {
                PaymentLinkMessageView(systemImage: "link", tint: .gray, title: String(localized: "This link was removed."))
            }
        }
        .navigationTitle("Payment Link")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $hardwareIntent, onDismiss: handleHardwareDismiss) { intent in
            HardwareSessionSheet(intent: intent, trezorManager: walletManager.trezorManager)
                .environmentObject(walletManager)
        }
    }

    private func content(_ record: EnvelopeRecord) -> some View {
        let display = PaymentLinkDisplay(record: record, walletManager: walletManager)
        return List {
            Section {
                VStack(spacing: 8) {
                    Text("\(XMRFormatter.format(EnvelopeRuntime.xmr(record.amount))) XMR")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    PaymentLinkStatusChip(display: display)
                    if display.status == .pending, !display.isExpired {
                        Text("Ready in about \(max(1, EnvelopeStatusRules.minutesUntilReady(confirmations: display.confirmations ?? 0))) min")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }

            Section {
                detailRow(String(localized: "Created"), record.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow(String(localized: "Expires"), record.expiryDate.formatted(date: .abbreviated, time: .omitted))
                if let reserve = record.feeReserve {
                    detailRow(String(localized: "Claim fee reserve"), "\(XMRFormatter.format(EnvelopeRuntime.xmr(reserve))) XMR")
                }
                if let txid = record.fundingTxid {
                    detailRow(String(localized: "Funding transaction"), ReceiveAddressLogic.shortAddress(txid), mono: true)
                }
                if let txid = record.settleTxid {
                    detailRow(String(localized: "Reclaim transaction"), ReceiveAddressLogic.shortAddress(txid), mono: true)
                }
            }

            Section {
                actions(record, display: display)
            } footer: {
                if let retryError {
                    Text(retryError).foregroundStyle(.red)
                } else if (display.status == .created || display.status == .notFunded) && fundedElsewhere(record) {
                    Text("Switch to \(record.walletName ?? String(localized: "the wallet that made this link")) to retry. Only that wallet can see whether the money went out.")
                } else if display.status == .pending && !display.isExpired {
                    Text("Reclaim opens when the link is ready, after 10 confirmations.")
                }
            }
        }
        .confirmationDialog(
            "Fund this link again?",
            isPresented: $showRetryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Send \(fundingTotal(record)) XMR") { retry(record) }
        } message: {
            Text("This sends \(fundingTotal(record)) XMR plus the network fee to the link. Do this only if the first try failed.")
        }
        .confirmationDialog(
            "Remove this link?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let id = record.id
                store.remove(record)
                Task { await EnvelopeRuntime.shared.deleteFiles(id: id) }
                dismiss()
            }
        } message: {
            if record.status.isSettled {
                Text("The link holds no money. This removes it from this list.")
            } else {
                Text("If the link holds money, this iPhone can no longer take it back. Anyone who has the link can still claim it.")
            }
        }
    }

    @ViewBuilder
    private func actions(_ record: EnvelopeRecord, display: PaymentLinkDisplay) -> some View {
        let canShare = record.link != nil
        switch display.status {
        case .created, .notFunded:
            Button {
                showRetryConfirmation = true
            } label: {
                Label(retrying ? "Sending…" : "Retry", systemImage: "arrow.clockwise")
                    .foregroundStyle(.brand)
            }
            .disabled(retrying || !walletManager.canSend || fundedElsewhere(record))
            .accessibilityLabel("Retry funding the link")
            removeButton
        case .pending, .ready:
            if display.isExpired {
                reclaimButton(record, enabled: display.status == .ready)
                if canShare { shareButton(record) }
            } else {
                if canShare { shareButton(record) }
                reclaimButton(record, enabled: display.status == .ready)
            }
        case .claimed, .reclaimed:
            removeButton
        }
    }

    private func shareButton(_ record: EnvelopeRecord) -> some View {
        Group {
            if let text = PaymentLinkFunder.shareText(for: record) {
                ShareLink(item: text) {
                    Label("Share again", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.brand)
                }
                .accessibilityLabel("Share the link again")
            }
        }
    }

    private func reclaimButton(_ record: EnvelopeRecord, enabled: Bool) -> some View {
        Button {
            PaymentLinksCoordinator.shared.present(record)
        } label: {
            Label("Reclaim", systemImage: "arrow.uturn.backward")
                .foregroundStyle(enabled ? Color.brand : Color.gray)
                .fontWeight(display(record).isExpired ? .semibold : .regular)
        }
        .disabled(!enabled)
        .accessibilityLabel("Reclaim the money")
        .accessibilityHint(enabled ? "Moves the money in this link back to your wallet" : "Available after 10 confirmations")
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .accessibilityLabel("Remove the link")
    }

    private func display(_ record: EnvelopeRecord) -> PaymentLinkDisplay {
        PaymentLinkDisplay(record: record, walletManager: walletManager)
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Retry

    private func retry(_ record: EnvelopeRecord) {
        retryError = nil
        guard !fundedElsewhere(record) else { return }
        if walletManager.requiresHardwareSession {
            do {
                try PaymentLinkFunder.save(record, networkType: walletManager.networkType)
            } catch {
                retryError = EnvelopeSession.message(for: error)
                return
            }
            walletManager.clearTerminalSessionState()
            hardwareIntent = .send(
                to: record.address,
                amount: EnvelopeRuntime.xmr(record.amount + (record.feeReserve ?? 0)),
                memo: PaymentLinkFunder.memo
            )
            return
        }
        retrying = true
        Task {
            defer { retrying = false }
            if requireAuthForSend {
                let approved = await biometricAuth.authenticateForTransaction(
                    reason: String(localized: "Confirm sending \(fundingTotal(record)) XMR")
                )
                guard approved else { return }
            }
            do {
                _ = try await PaymentLinkFunder.fund(record, walletManager: walletManager)
                HapticFeedback.shared.transactionSuccess()
                await walletManager.refresh()
            } catch {
                retryError = EnvelopeSession.message(for: error)
                HapticFeedback.shared.error()
            }
        }
    }

    private func handleHardwareDismiss() {
        switch walletManager.lastHardwareSessionOutcome {
        case .sentTransaction(let txid):
            PaymentLinkFunder.markFunded(id: recordId, txid: txid)
        default:
            PaymentLinkFunder.markNotFunded(id: recordId)
        }
    }
}
