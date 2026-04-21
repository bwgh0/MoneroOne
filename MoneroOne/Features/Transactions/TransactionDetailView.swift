import SwiftUI

struct TransactionDetailView: View {
    let transaction: MoneroTransaction
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("isTestnet") private var isTestnet = false

    @State private var txKey: String?
    @State private var txKeyLookedUp = false
    @State private var copiedField: CopyField?

    private enum CopyField: String { case txId, address, txKey }

    /// For incoming transactions, determine which subaddress received the funds
    private var receivingSubaddressLabel: String? {
        guard transaction.type == .incoming, !transaction.address.isEmpty else { return nil }

        if transaction.address == walletManager.primaryAddress {
            return "Main Address"
        }

        if let subaddr = walletManager.subaddresses.first(where: { $0.address == transaction.address }) {
            return "Subaddress #\(subaddr.index)"
        }

        return "Subaddress"
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
                .accessibilityLabel("Amount: \(transaction.type == .incoming ? "plus" : "minus") \(XMRFormatter.format(transaction.amount)) XMR")

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
                    label: "Transaction ID",
                    value: transaction.id,
                    field: .txId
                )

                if transaction.type == .incoming && !transaction.address.isEmpty {
                    copyableRow(
                        label: "Received on",
                        trailingLabel: receivingSubaddressLabel,
                        value: transaction.address,
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

                if transaction.type == .outgoing && !transaction.address.isEmpty {
                    copyableRow(
                        label: "Sent to",
                        value: transaction.address,
                        field: .address
                    )
                }

                if transaction.type == .outgoing {
                    txKeyRow
                }

                if let url = blockExplorerURL {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: "safari")
                                .foregroundColor(.accentColor)
                            Text("View in Block Explorer")
                            Spacer()
                            Text(isTestnet ? "Testnet" : "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityLabel("View in block explorer\(isTestnet ? ", testnet" : "")")
                    .accessibilityHint("Opens the transaction in a web browser")
                }
            }
        }
        .refreshable {
            await walletManager.refresh()
        }
        .navigationTitle(transaction.type == .incoming ? "Received" : "Sent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard transaction.type == .outgoing, !txKeyLookedUp else { return }
            txKey = walletManager.getTxKey(txId: transaction.id)
            txKeyLookedUp = true
        }
    }

    @ViewBuilder
    private var txKeyRow: some View {
        if let key = txKey, !key.isEmpty {
            copyableRow(label: "Transaction Key", value: key, field: .txKey)
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
                    copy(value, field: field)
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
        .accessibilityLabel("\(label): \(value)")
    }

    private func copy(_ text: String, field: CopyField) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedField = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedField == field { copiedField = nil }
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: transaction.timestamp)
    }
}

#Preview {
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
            memo: nil
        ))
        .environmentObject(WalletManager())
    }
}
