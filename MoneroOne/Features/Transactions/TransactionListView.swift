import SwiftUI

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var transactions: [Transaction] = []

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    emptyState
                } else {
                    transactionList
                }
            }
            .navigationTitle("History")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Transactions")
                .font(.headline)

            Text("Your transaction history will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var transactionList: some View {
        List(transactions) { transaction in
            NavigationLink {
                TransactionDetailView(transaction: transaction)
            } label: {
                TransactionRow(transaction: transaction)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Transaction Model

struct Transaction: Identifiable {
    let id: String
    let type: TransactionType
    let amount: Decimal
    let fee: Decimal?
    let address: String
    let timestamp: Date
    let confirmations: Int
    let status: TransactionStatus

    enum TransactionType {
        case incoming
        case outgoing
    }

    enum TransactionStatus {
        case pending
        case confirmed
        case failed
    }
}

// MARK: - Transaction Row

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.title3)
                .foregroundColor(transaction.type == .incoming ? .green : .orange)
                .frame(width: 40, height: 40)
                .background(
                    (transaction.type == .incoming ? Color.green : Color.orange)
                        .opacity(0.15)
                )
                .cornerRadius(10)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.type == .incoming ? "Received" : "Sent")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Amount
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(transaction.type == .incoming ? .green : .primary)

                Text(statusText)
                    .font(.caption2)
                    .foregroundColor(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: transaction.timestamp)
    }

    private var statusText: String {
        switch transaction.status {
        case .pending: return "Pending"
        case .confirmed: return "\(transaction.confirmations) confirmations"
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

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 8
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }
}

#Preview {
    TransactionListView()
        .environmentObject(WalletManager())
}
