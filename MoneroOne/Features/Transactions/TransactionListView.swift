import SwiftUI

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var searchText = ""
    @State private var filterType: FilterType = .all

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
        List {
            if filteredTransactions.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredTransactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("All Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search by ID, address, or memo")
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
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if !searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No results for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if filterType != .all {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No \(filterType.rawValue.lowercased()) transactions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No transactions yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Transaction Row (Standard List Style)

struct TransactionRow: View {
    let transaction: MoneroTransaction

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(transaction.type == .incoming ? .green : .orange)
                .frame(width: 36, height: 36)
                .background(
                    (transaction.type == .incoming ? Color.green : Color.orange)
                        .opacity(0.15)
                )
                .cornerRadius(8)

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

            // Amount & Status
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(transaction.type == .incoming ? .green : .primary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(statusColor)
                }
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
    NavigationStack {
        TransactionListView()
            .environmentObject(WalletManager())
    }
}
