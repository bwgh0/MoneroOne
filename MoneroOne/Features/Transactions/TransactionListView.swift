import SwiftUI

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var searchText = ""
    @State private var filterType: FilterType = .all
    @State private var showFilters = false
    @State private var selectedTransaction: MoneroTransaction?

    enum FilterType: String, CaseIterable {
        case all = "All"
        case incoming = "Received"
        case outgoing = "Sent"
        case pending = "Pending"
    }

    private var filteredTransactions: [MoneroTransaction] {
        var result = walletManager.transactions

        // Apply type filter
        switch filterType {
        case .all:
            break
        case .incoming:
            result = result.filter { $0.type == .incoming }
        case .outgoing:
            result = result.filter { $0.type == .outgoing }
        case .pending:
            result = result.filter { $0.status == .pending }
        }

        // Apply search filter
        if !searchText.isEmpty {
            result = result.filter { tx in
                tx.id.localizedCaseInsensitiveContains(searchText) ||
                tx.address.localizedCaseInsensitiveContains(searchText) ||
                (tx.memo?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if walletManager.transactions.isEmpty {
                    emptyState
                } else {
                    transactionList
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search transactions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(FilterType.allCases, id: \.self) { type in
                            Button {
                                filterType = type
                            } label: {
                                HStack {
                                    Text(type.rawValue)
                                    if filterType == type {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: filterType == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .foregroundColor(filterType == .all ? .primary : .orange)
                    }
                }
            }
            .refreshable {
                await walletManager.refresh()
            }
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
        List {
            if filteredTransactions.isEmpty && !searchText.isEmpty {
                Text("No results for \"\(searchText)\"")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredTransactions) { transaction in
                    Button {
                        selectedTransaction = transaction
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(item: $selectedTransaction) { transaction in
            TransactionDetailView(transaction: transaction)
        }
    }
}

// MARK: - Transaction Row

struct TransactionRow: View {
    let transaction: MoneroTransaction

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
        .contentShape(Rectangle())
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
