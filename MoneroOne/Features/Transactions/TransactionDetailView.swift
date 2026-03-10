import SwiftUI

struct TransactionDetailView: View {
    let transaction: MoneroTransaction
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("isTestnet") private var isTestnet = false

    /// For incoming transactions, determine which subaddress received the funds
    private var receivingSubaddressLabel: String? {
        guard transaction.type == .incoming, !transaction.address.isEmpty else { return nil }

        // Check if it's the main address
        if transaction.address == walletManager.primaryAddress {
            return "Main Address"
        }

        // Try to find matching subaddress
        if let subaddr = walletManager.subaddresses.first(where: { $0.address == transaction.address }) {
            return "Subaddress #\(subaddr.index)"
        }

        // Address found but not in our current list (might be old)
        return "Subaddress"
    }

    private var blockExplorerURL: URL? {
        if isTestnet {
            // Testnet block explorer
            return URL(string: "https://testnet.xmrchain.net/tx/\(transaction.id)")
        } else {
            // Mainnet block explorer
            return URL(string: "https://xmrchain.net/tx/\(transaction.id)")
        }
    }

    var body: some View {
        List {
            Section {
                // Amount
                HStack {
                    Text("Amount")
                    Spacer()
                    Text("\(transaction.type == .incoming ? "+" : "-")\(XMRFormatter.format(transaction.amount)) XMR")
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Amount: \(transaction.type == .incoming ? "plus" : "minus") \(XMRFormatter.format(transaction.amount)) XMR")

                // Fee (for outgoing)
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

                // Status
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

                // Confirmations
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

                // Memo
                if let memo = transaction.memo, !memo.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memo")
                        Text(memo)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Details") {
                // Date
                HStack {
                    Text("Date")
                    Spacer()
                    Text(formattedDate)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Date: \(formattedDate)")

                // Transaction ID
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transaction ID")
                    Text(transaction.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transaction ID: \(transaction.id)")

                // For incoming: show which subaddress received the funds
                if transaction.type == .incoming && !transaction.address.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Received on")
                            Spacer()
                            if let label = receivingSubaddressLabel {
                                Text(label)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(transaction.address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Received on \(receivingSubaddressLabel ?? "address"): \(transaction.address)")

                    // Privacy note about sender
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

                // For outgoing: show recipient if available
                if transaction.type == .outgoing && !transaction.address.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sent to")
                        Text(transaction.address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sent to: \(transaction.address)")
                }
            }

            Section {
                Button {
                    UIPasteboard.general.string = transaction.id
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Transaction ID")
                    }
                }
                .accessibilityLabel("Copy transaction ID")
                .accessibilityHint("Copies the transaction ID to clipboard")

                if let url = blockExplorerURL {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: "safari")
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
