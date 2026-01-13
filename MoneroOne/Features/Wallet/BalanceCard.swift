import SwiftUI

struct BalanceCard: View {
    let balance: Decimal
    let unlockedBalance: Decimal
    let syncState: WalletManager.SyncState

    var body: some View {
        VStack(spacing: 16) {
            // Sync Status
            HStack {
                Circle()
                    .fill(syncStatusColor)
                    .frame(width: 8, height: 8)
                Text(syncStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Main Balance
            VStack(spacing: 4) {
                Text(formatXMR(balance))
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                Text("XMR")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            // Unlocked Balance
            if unlockedBalance != balance {
                HStack {
                    Text("Available:")
                        .foregroundColor(.secondary)
                    Text(formatXMR(unlockedBalance))
                        .fontWeight(.medium)
                    Text("XMR")
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }

            // Sync Progress
            if case .syncing(let progress, let remaining) = syncState {
                VStack(spacing: 4) {
                    ProgressView(value: progress / 100)
                        .tint(.orange)
                    if let remaining = remaining {
                        Text("\(Int(progress))% synced - \(remaining) blocks remaining")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(Int(progress))% synced")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
    }

    private var syncStatusColor: Color {
        switch syncState {
        case .idle: return .gray
        case .connecting: return .yellow
        case .syncing: return .orange
        case .synced: return .green
        case .error: return .red
        }
    }

    private var syncStatusText: String {
        switch syncState {
        case .idle: return "Idle"
        case .connecting: return "Connecting..."
        case .syncing: return "Syncing..."
        case .synced: return "Synced"
        case .error(let msg): return "Error: \(msg)"
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
    VStack(spacing: 20) {
        BalanceCard(
            balance: 1.234567890123,
            unlockedBalance: 1.234567890123,
            syncState: .synced
        )

        BalanceCard(
            balance: 5.5,
            unlockedBalance: 3.2,
            syncState: .syncing(progress: 65, remaining: 1000)
        )
    }
    .padding()
}
