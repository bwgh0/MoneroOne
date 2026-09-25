import SwiftUI
import SafariServices

struct TransactionDetailView: View {
    let transaction: MoneroTransaction
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @EnvironmentObject var priceHistoryService: PriceHistoryService
    @AppStorage("isTestnet") private var isTestnet = false

    @State private var txKey: String?
    @State private var txKeyLookedUp = false
    @State private var copiedField: CopyField?
    @State private var explorerURL: URL?

    private enum CopyField: Hashable {
        case txId
        case address
        case destination(Int)
        case txKey
        case all
    }

    private var subaddressSummaries: [SubaddressSummary] {
        walletManager.subaddresses.map(SubaddressSummary.init)
    }

    /// For incoming transactions, the name of the subaddress that
    /// received the funds ("Main Address", the user's label, or
    /// "Subaddress #n").
    private var receivingSubaddressLabel: String? {
        guard transaction.type == .incoming else { return nil }
        return TransactionDetailLogic.receivedOnLabel(
            subaddressIndex: transaction.subaddressIndex,
            address: transaction.address,
            primaryAddress: walletManager.primaryAddress,
            subaddresses: subaddressSummaries
        )
    }

    /// The receiving address to show. Falls back to the wallet's
    /// address book when the transaction row carries only the index.
    private var receivingAddress: String? {
        guard transaction.type == .incoming else { return nil }
        return TransactionDetailLogic.receivedOnAddress(
            subaddressIndex: transaction.subaddressIndex,
            address: transaction.address,
            primaryAddress: walletManager.primaryAddress,
            subaddresses: subaddressSummaries
        )
    }

    private var sentToRows: [SentToRow] {
        guard transaction.type == .outgoing else { return [] }
        return TransactionDetailLogic.sentToRows(
            destinations: transaction.destinations,
            fallbackAddress: transaction.address
        )
    }

    private var blockExplorerURL: URL? {
        if isTestnet {
            return URL(string: "https://testnet.xmrchain.net/tx/\(transaction.id)")
        } else {
            return URL(string: "https://xmrchain.net/tx/\(transaction.id)")
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Amount")
                    Spacer()
                    Text("\(transaction.type == .incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount)) XMR")
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(transaction.type == .incoming
                    ? String(localized: "Amount: plus \(XMRFormatter.format(transaction.amount)) XMR", comment: "VoiceOver: amount received")
                    : String(localized: "Amount: minus \(XMRFormatter.format(transaction.amount)) XMR", comment: "VoiceOver: amount sent"))

                // Fiat value at the time it happened, from price history;
                // hidden until the history has loaded.
                if let valueAtTime = priceHistoryService.fiatValue(xmr: transaction.amount, at: transaction.timestamp)
                    .map({ priceService.formatFiat($0) }) {
                    let label = transaction.type == .incoming ? String(localized: "Value when received") : String(localized: "Value when sent")
                    HStack {
                        Text(label)
                        Spacer()
                        Text(valueAtTime)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(label): \(valueAtTime)")
                }

                // Fiat value at the live price; hidden until one is known.
                if let valueToday = priceService.formatFiatValue(transaction.amount) {
                    HStack {
                        Text("Value today")
                        Spacer()
                        Text(valueToday)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Value today: \(valueToday)")
                }

                if transaction.type == .outgoing {
                    HStack {
                        Text("Fee")
                        Spacer()
                        Text("\(XMRFormatter.format(transaction.fee)) XMR")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fee: \(XMRFormatter.format(transaction.fee)) XMR")
                }

                HStack {
                    Text("Status")
                    Spacer()
                    if transaction.isStatusLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(transaction.displayStatusColor)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(transaction.displayStatusText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(transaction.displayStatusText)")

                HStack {
                    Text("Confirmations")
                    Spacer()
                    if let confirmations = transaction.confirmations {
                        Text("\(confirmations)")
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Confirmations: \(transaction.confirmations ?? 0)")

                if let memo = transaction.memo, !memo.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memo")
                        Text(memo)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Details") {
                HStack {
                    Text("Date")
                    Spacer()
                    Text(formattedDate)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Date: \(formattedDate)")

                copyableRow(
                    label: String(localized: "Transaction ID"),
                    value: transaction.id,
                    field: .txId
                )

                if transaction.type == .incoming, let receivingAddress {
                    copyableRow(
                        label: String(localized: "Received on"),
                        trailingLabel: receivingSubaddressLabel,
                        value: receivingAddress,
                        field: .address
                    )

                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.green)
                        Text("Sender address hidden by Monero privacy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sender address hidden by Monero privacy")
                }

                if transaction.type == .outgoing {
                    if sentToRows.isEmpty {
                        recipientUnavailableRow
                    } else {
                        ForEach(Array(sentToRows.enumerated()), id: \.offset) { position, row in
                            copyableRow(
                                label: row.label,
                                trailingLabel: row.amountLabel,
                                value: row.address,
                                field: .destination(position)
                            )
                        }
                    }

                    txKeyRow
                }

                if let url = blockExplorerURL {
                    Button {
                        explorerURL = url
                    } label: {
                        HStack {
                            Image(systemName: "safari")
                                .foregroundColor(.accentColor)
                            Text("View in Block Explorer")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(isTestnet ? "Testnet" : "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        // Without an explicit shape, taps on the
                        // empty space the `Spacer()` occupies pass
                        // through instead of firing the button.
                        // Make the whole row clickable.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View in block explorer\(isTestnet ? String(localized: ", testnet") : "")")
                    .accessibilityHint("Opens the transaction in an in-app browser")
                }

                copyAllRow
            }
        }
        .refreshable {
            await walletManager.refresh()
        }
        .navigationTitle(transaction.type == .incoming ? "Received" : "Sent")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .task {
            guard transaction.type == .outgoing, !txKeyLookedUp else { return }
            txKey = walletManager.getTxKey(txId: transaction.id)
            txKeyLookedUp = true
        }
        .sheet(item: $explorerURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }

    /// Monero does not put recipients on chain; wallet2 keeps them
    /// only for sends it built itself, so a restored wallet has none.
    private var recipientUnavailableRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recipient")
            Text("Not available for transactions sent before this wallet was restored")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recipient not available for transactions sent before this wallet was restored")
    }

    @ViewBuilder
    private var txKeyRow: some View {
        if let key = txKey, !key.isEmpty {
            copyableRow(label: String(localized: "Transaction Key"), value: key, field: .txKey)
        } else if txKeyLookedUp {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transaction Key")
                Text("Stored only on the device that originally sent this transaction. Recipients use this key with the transaction ID and destination address to verify the payment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transaction key unavailable on this device")
        }
    }

    /// Copies every row above as one text block. Sits at the end of
    /// the section, next to the explorer link, in the same row style.
    private var copyAllRow: some View {
        let copied = copiedField == .all
        return Button {
            copyAllDetails()
        } label: {
            HStack {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : "Copy All Details")
                    .foregroundColor(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction.copyAllButton")
        .accessibilityLabel(copied ? "All details copied" : "Copy all details")
        .accessibilityHint("Copies every field of this transaction as text")
    }

    @ViewBuilder
    private func copyableRow(
        label: String,
        trailingLabel: String? = nil,
        value: String,
        field: CopyField
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                if let trailingLabel {
                    Text(trailingLabel)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copy(value, field: field, secret: field == .txKey)
                } label: {
                    Image(systemName: copiedField == field ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(copiedField == field ? Color.green : Color.accentColor)
                        .symbolEffect(.bounce, value: copiedField == field)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedField == field ? "\(label) copied" : "Copy \(label.lowercased())")
            }
        }
        .accessibilityElement(children: .combine)
        // Speak the trailing name too ("Received on, Donation: 84…"); it was
        // visible on screen but VoiceOver skipped it.
        .accessibilityLabel("\(label)\(trailingLabel.map { ", \($0)" } ?? ""): \(value)")
    }

    private func copyAllDetails() {
        let lines = TransactionDetailLogic.detailLines(
            transaction: transaction,
            dateText: formattedDate,
            receivedOnLabel: receivingSubaddressLabel,
            receivedOnAddress: receivingAddress,
            sentTo: sentToRows,
            txKey: txKey,
            explorerURL: blockExplorerURL,
            valueAtTime: priceHistoryService.fiatValue(xmr: transaction.amount, at: transaction.timestamp)
                .map { priceService.formatFiat($0) },
            valueToday: priceService.formatFiatValue(transaction.amount)
        )
        copy(
            TransactionDetailLogic.copyAllText(lines),
            field: .all,
            secret: lines.contains(where: \.isSecret)
        )
    }

    /// `secret` routes the text through `SecureClipboard`: local
    /// only and expiring, for blocks that carry the transaction key.
    private func copy(_ text: String, field: CopyField, secret: Bool = false) {
        if secret {
            SecureClipboard.copySecret(text)
        } else {
            UIPasteboard.general.string = text
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy(duration: 0.25)) {
            copiedField = field
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedField == field {
                withAnimation(.snappy(duration: 0.25)) {
                    copiedField = nil
                }
            }
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: transaction.timestamp)
    }
}

// MARK: - Detail logic (pure, covered by TransactionScreenLogicTests)

/// One "Sent to" row of the Details section.
struct SentToRow: Equatable {
    /// "Sent to", or "Sent to (1 of 2)" when there are several.
    let label: String
    /// The destination's amount, shown only when there are several.
    let amountLabel: String?
    let address: String
}

/// One line of the Copy All block.
struct TransactionDetailLine: Equatable {
    let label: String
    let value: String
    /// Spend-linkability material (the transaction key). A block that
    /// holds one goes through `SecureClipboard`.
    var isSecret = false
}

enum TransactionDetailLogic {
    /// Name of the receiving subaddress. `subaddressIndex` is the
    /// source of truth; the address reverse-match only covers rows
    /// captured before the index existed.
    static func receivedOnLabel(
        subaddressIndex: Int?,
        address: String,
        primaryAddress: String,
        subaddresses: [SubaddressSummary]
    ) -> String? {
        if let subaddressIndex {
            let label = subaddresses.first { $0.index == subaddressIndex }?.label ?? ""
            return SubaddressName.display(index: subaddressIndex, label: label)
        }

        guard !address.isEmpty else { return nil }
        if address == primaryAddress {
            return SubaddressName.display(index: 0, label: "")
        }
        if let match = subaddresses.first(where: { $0.address == address }) {
            return SubaddressName.display(index: match.index, label: match.label)
        }
        return String(localized: "Subaddress")
    }

    /// The address to show for "Received on": the row's own address,
    /// else the wallet's address at `subaddressIndex`.
    static func receivedOnAddress(
        subaddressIndex: Int?,
        address: String,
        primaryAddress: String,
        subaddresses: [SubaddressSummary]
    ) -> String? {
        if !address.isEmpty { return address }
        guard let subaddressIndex else { return nil }
        if subaddressIndex == 0, !primaryAddress.isEmpty { return primaryAddress }
        let match = subaddresses.first { $0.index == subaddressIndex }?.address
        return (match?.isEmpty == false) ? match : nil
    }

    /// One row per destination. An outgoing row that has no
    /// destinations but still an address (older hardware snapshots)
    /// gets a single plain row; no destinations and no address gives
    /// an empty list, which the view shows as "Recipient: not available".
    static func sentToRows(
        destinations: [MoneroTransactionDestination],
        fallbackAddress: String
    ) -> [SentToRow] {
        if destinations.isEmpty {
            guard !fallbackAddress.isEmpty else { return [] }
            return [SentToRow(label: String(localized: "Sent to"), amountLabel: nil, address: fallbackAddress)]
        }
        if destinations.count == 1 {
            return [SentToRow(label: String(localized: "Sent to"), amountLabel: nil, address: destinations[0].address)]
        }
        return destinations.enumerated().map { position, destination in
            SentToRow(
                label: String(localized: "Sent to (\(position + 1) of \(destinations.count))"),
                amountLabel: "\(XMRFormatter.format(destination.amount)) XMR",
                address: destination.address
            )
        }
    }

    /// Every field the detail screen shows, in screen order. Missing
    /// fields (no memo, key not loaded, status still loading) are left
    /// out. To add a row, append one `add(...)` where it belongs.
    static func detailLines(
        transaction: MoneroTransaction,
        dateText: String,
        receivedOnLabel: String?,
        receivedOnAddress: String?,
        sentTo: [SentToRow],
        txKey: String?,
        explorerURL: URL?,
        valueAtTime: String? = nil,
        valueToday: String? = nil
    ) -> [TransactionDetailLine] {
        var lines: [TransactionDetailLine] = []
        func add(_ label: String, _ value: String?, secret: Bool = false) {
            guard let value, !value.isEmpty else { return }
            lines.append(TransactionDetailLine(label: label, value: value, isSecret: secret))
        }

        let incoming = transaction.type == .incoming
        add(String(localized: "Type"), incoming ? String(localized: "Received") : String(localized: "Sent"))
        add(String(localized: "Amount"), "\(incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount)) XMR")
        if !incoming {
            add(String(localized: "Fee"), "\(XMRFormatter.format(transaction.fee)) XMR")
        }
        add(incoming ? String(localized: "Value when received") : String(localized: "Value when sent"), valueAtTime)
        add(String(localized: "Value today"), valueToday)
        add(String(localized: "Status"), transaction.displayStatusText)
        if let confirmations = transaction.confirmations {
            add(String(localized: "Confirmations"), "\(confirmations)")
        }
        add(String(localized: "Date"), dateText)
        add(String(localized: "Memo"), transaction.memo)
        add(String(localized: "Transaction ID"), transaction.id)

        if incoming {
            let label = receivedOnLabel.map { String(localized: "Received on (\($0))") } ?? String(localized: "Received on")
            add(label, receivedOnAddress)
        } else if sentTo.isEmpty {
            add(String(localized: "Recipient"), String(localized: "Not available for transactions sent before this wallet was restored"))
        } else {
            for row in sentTo {
                let label = row.amountLabel.map { "\(row.label), \($0)" } ?? row.label
                add(label, row.address)
            }
        }

        add(String(localized: "Transaction Key"), txKey, secret: true)
        add(String(localized: "Block Explorer"), explorerURL?.absoluteString)

        return lines
    }

    static func copyAllText(_ lines: [TransactionDetailLine]) -> String {
        lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

#Preview {
    let priceService = PriceService()
    let priceHistoryService = PriceHistoryService(priceService: priceService)
    NavigationStack {
        TransactionDetailView(transaction: MoneroTransaction(
            id: "abc123def456",
            type: .outgoing,
            amount: 1.5,
            fee: 0.00001,
            address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H",
            timestamp: Date(),
            confirmations: 10,
            status: .confirmed,
            memo: nil,
            blockHeight: nil,
            destinations: [
                MoneroTransactionDestination(
                    address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H",
                    amount: 1.0
                ),
                MoneroTransactionDestination(
                    address: "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A",
                    amount: 0.5
                )
            ]
        ))
        .environmentObject(WalletManager())
        .environmentObject(priceService)
        .environmentObject(priceHistoryService)
    }
}

/// `SFSafariViewController` wrapper that keeps the block-explorer
/// link inside MoneroOne instead of bouncing the user out to
/// Safari. Reader mode disabled — block-explorer pages aren't
/// articles and the reader-extraction heuristics tend to garble
/// the tx data we actually want to show.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// `.sheet(item:)` requires Identifiable. URL doesn't conform by
/// default; using `absoluteString` as the id is safe since the
/// presented URL only changes when the user taps the row.
extension URL: Identifiable {
    public var id: String { absoluteString }
}
