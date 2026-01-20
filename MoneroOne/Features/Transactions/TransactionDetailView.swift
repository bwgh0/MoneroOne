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
                    Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount)) XMR")
                        .fontWeight(.semibold)
                        .foregroundColor(transaction.type == .incoming ? .green : .primary)
                }

                // Fee (for outgoing)
                if transaction.type == .outgoing {
                    HStack {
                        Text("Fee")
                        Spacer()
                        Text("\(formatXMR(transaction.fee)) XMR")
                            .foregroundColor(.secondary)
                    }
                }

                // Status
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(combinedStatusColor)
                            .frame(width: 8, height: 8)
                        Text(combinedStatusText)
                    }
                }

                // Confirmations
                HStack {
                    Text("Confirmations")
                    Spacer()
                    Text("\(transaction.confirmations)")
                        .foregroundColor(.secondary)
                }

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

                // Transaction ID
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transaction ID")
                    Text(transaction.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

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

                    // Privacy note about sender
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.green)
                        Text("Sender address hidden by Monero privacy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
                }
            }
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

    private var combinedStatusText: String {
        if transaction.status == .failed {
            return "Failed"
        }
        let confs = transaction.confirmations
        if confs == 0 {
            return "Pending"
        } else if confs < 10 {
            return "Locked"
        } else {
            return "Confirmed"
        }
    }

    private var combinedStatusColor: Color {
        if transaction.status == .failed {
            return .red
        }
        let confs = transaction.confirmations
        if confs == 0 {
            return .orange
        } else if confs < 10 {
            return .orange
        } else {
            return .green
        }
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
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
