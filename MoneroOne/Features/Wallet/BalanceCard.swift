import SwiftUI

struct BalanceCard: View {
    let balance: Decimal
    let unlockedBalance: Decimal
    let syncState: WalletManager.SyncState
    @ObservedObject var priceService: PriceService
    var onPriceChangeTap: (() -> Void)? = nil
    var onCardTap: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

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

                // Price change indicator (tappable)
                if let change = priceService.priceChange24h {
                    Button {
                        onPriceChangeTap?()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2)
                            Text(priceService.formatPriceChange() ?? "")
                                .font(.caption)
                        }
                        .foregroundColor(change >= 0 ? .green : .red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((change >= 0 ? Color.green : Color.red).opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }

            // Main Balance
            HStack(spacing: 16) {
                // Monero symbol with tight circular mask
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .scaleEffect(1.15) // Scale up slightly before clipping for tighter crop
                    .clipShape(Circle()) // Clip again after scale

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(formatXMR(balance))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)

                        Text("XMR")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.2), value: balance)

                    // Fiat value
                    if let fiatValue = priceService.formatFiatValue(balance) {
                        Text("≈ \(fiatValue)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: balance)
                    }
                }

                Spacer()
            }

            // Unlocked Balance
            if unlockedBalance != balance {
                VStack(spacing: 4) {
                    HStack {
                        Text("Available:")
                            .foregroundColor(.secondary)
                        Text(formatXMR(unlockedBalance))
                            .fontWeight(.medium)
                        Text("XMR")
                            .foregroundColor(.secondary)
                        if let fiat = priceService.formatFiatValue(unlockedBalance) {
                            Text("(\(fiat))")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.subheadline)

                    // Explanation for locked funds
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Locked until recent transactions confirm")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                }
            }

            // Sync Progress
            if case .syncing(let progress, let remaining) = syncState {
                VStack(spacing: 4) {
                    ProgressView(value: progress / 100)
                        .tint(.orange)
                    if let remaining = remaining {
                        Text("\(Int(progress))% synced - \(formatBlockCount(remaining)) blocks remaining")
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
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onCardTap?()
        }
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
        case .syncing: return "Scanning for transactions..."
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

    private func formatBlockCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        BalanceCard(
            balance: 1.234567890123,
            unlockedBalance: 1.234567890123,
            syncState: .synced,
            priceService: PriceService()
        )

        BalanceCard(
            balance: 5.5,
            unlockedBalance: 3.2,
            syncState: .syncing(progress: 65, remaining: 1000),
            priceService: PriceService()
        )
    }
    .padding()
}
