import SwiftUI

struct BalanceCard: View {
    let balance: Decimal
    let unlockedBalance: Decimal
    let syncState: WalletManager.SyncState
    let connectionStage: ConnectionStage
    @ObservedObject var priceService: PriceService
    var onPriceChangeTap: (() -> Void)? = nil
    var onCardTap: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            // Sync Status - use progressive indicator when connecting, simple status when synced
            HStack {
                if case .synced = syncState {
                    // Simple synced indicator
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Synced")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if case .error(let msg) = syncState {
                    // Error indicator
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Error: \(msg)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else {
                    // Progressive connection indicator
                    ConnectionStepIndicator(
                        stage: connectionStage,
                        syncProgress: syncProgress
                    )
                }
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
                        Text(XMRFormatter.format(balance))
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
                        Text(XMRFormatter.format(unlockedBalance))
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

    /// Extract sync progress from syncState for the step indicator
    private var syncProgress: Double? {
        if case .syncing(let progress, _) = syncState {
            return progress
        }
        return nil
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

// MARK: - Connection Step Indicator

/// Progressive connection status indicator with 6 stages
/// Shows: Network -> Node -> Connecting -> Loading -> Syncing -> Synced
private struct ConnectionStepIndicator: View {
    let stage: ConnectionStage
    let syncProgress: Double?  // nil if not syncing, 0-100 if syncing

    private let stageCount = 6
    private let dotSize: CGFloat = 8
    private let lineWidth: CGFloat = 12
    private let lineHeight: CGFloat = 2

    var body: some View {
        VStack(spacing: 6) {
            // Step dots and lines
            HStack(spacing: 0) {
                ForEach(0..<stageCount, id: \.self) { index in
                    stepDot(for: index)

                    if index < stageCount - 1 {
                        stepLine(for: index)
                    }
                }
            }

            // Status text
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func stepDot(for index: Int) -> some View {
        let isCompleted = index < stage.stageIndex
        let isActive = index == stage.stageIndex
        let isFinal = index == stageCount - 1 && stage == .synced

        ZStack {
            if isCompleted || isFinal {
                // Completed or final synced state - filled dot
                Circle()
                    .fill(isFinal ? Color.green : Color.orange)
                    .frame(width: dotSize, height: dotSize)
            } else if isActive {
                // Active state - pulsing dot
                Circle()
                    .fill(Color.orange)
                    .frame(width: dotSize, height: dotSize)
                    .modifier(PulsingModifier())
            } else {
                // Pending state - gray outline
                Circle()
                    .stroke(Color.gray.opacity(0.4), lineWidth: 1.5)
                    .frame(width: dotSize, height: dotSize)
            }
        }
    }

    private func stepLine(for index: Int) -> some View {
        Rectangle()
            .fill(index < stage.stageIndex ? Color.orange : Color.gray.opacity(0.3))
            .frame(width: lineWidth, height: lineHeight)
    }

    private var statusText: String {
        if case .syncing = stage, let progress = syncProgress {
            return "Scanning \(Int(progress))%..."
        }
        return stage.displayText
    }
}

/// Pulsing animation modifier for active dots
private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 0.9)
            .opacity(isPulsing ? 1.0 : 0.7)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true)
                ) {
                    isPulsing = true
                }
            }
    }
}

#Preview("Synced") {
    BalanceCard(
        balance: 1.234567890123,
        unlockedBalance: 1.234567890123,
        syncState: .synced,
        connectionStage: .synced,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Syncing") {
    BalanceCard(
        balance: 5.5,
        unlockedBalance: 3.2,
        syncState: .syncing(progress: 65, remaining: 1000),
        connectionStage: .syncing,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Connecting") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .connecting,
        connectionStage: .connecting,
        priceService: PriceService()
    )
    .padding()
}

#Preview("Loading Blocks") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .connecting,
        connectionStage: .loadingBlocks(wallet: 2_100_000, daemon: 3_450_000),
        priceService: PriceService()
    )
    .padding()
}

#Preview("Error") {
    BalanceCard(
        balance: 0,
        unlockedBalance: 0,
        syncState: .error("Connection timeout"),
        connectionStage: .reachingNode,
        priceService: PriceService()
    )
    .padding()
}
