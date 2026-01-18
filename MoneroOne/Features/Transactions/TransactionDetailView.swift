import SwiftUI

struct TransactionDetailView: View {
    let transaction: MoneroTransaction

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

                // Confirmations
                HStack {
                    Text("Confirmations")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(confirmationColor)
                            .frame(width: 8, height: 8)
                        Text(confirmationText)
                            .foregroundColor(.secondary)
                    }
                }

                // Status
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                    }
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

                // Address
                if !transaction.address.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.type == .incoming ? "From" : "To")
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

                Link(destination: URL(string: "https://blockchair.com/monero/transaction/\(transaction.id)")!) {
                    HStack {
                        Image(systemName: "safari")
                        Text("View in Block Explorer")
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

    private var statusText: String {
        switch transaction.status {
        case .pending: return "Pending"
        case .confirmed: return "Confirmed"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch transaction.status {
        case .pending: return .orange
        case .confirmed: return .green
        case .failed: return .red
        }
    }

    private var confirmationText: String {
        let confs = transaction.confirmations
        if confs == 0 {
            return "Unconfirmed"
        } else if confs < 10 {
            return "\(confs)/10 (locked)"
        } else {
            return "\(confs) (unlocked)"
        }
    }

    private var confirmationColor: Color {
        let confs = transaction.confirmations
        if confs == 0 {
            return .red
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
    }
}
