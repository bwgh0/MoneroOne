import SwiftUI

struct TransactionListView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var searchText = ""
    @State private var filterType: FilterType = .all
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
            .navigationDestination(item: $selectedTransaction) { transaction in
                TransactionDetailView(transaction: transaction)
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
        ScrollView {
            LazyVStack(spacing: 12) {
                if filteredTransactions.isEmpty && !searchText.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(filteredTransactions) { transaction in
                        TransactionCard(transaction: transaction) {
                            selectedTransaction = transaction
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            await walletManager.refresh()
        }
    }
}

// MARK: - Transaction Card (Liquid Glass Style)

struct TransactionCard: View {
    let transaction: MoneroTransaction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 44, height: 44)

                    Image(systemName: transaction.type == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(iconColor)
                }

                // Details
                VStack(alignment: .leading, spacing: 4) {
                    Text(transaction.type == .incoming ? "Received" : "Sent")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Amount & Status
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(transaction.type == .incoming ? "+" : "-")\(formatXMR(transaction.amount))")
                        .font(.subheadline)
                        .fontWeight(.bold)
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

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(TransactionCardButtonStyle())
    }

    private var iconColor: Color {
        transaction.type == .incoming ? .green : .orange
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

// MARK: - Custom Button Style for Cards

struct TransactionCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    TransactionListView()
        .environmentObject(WalletManager())
}
