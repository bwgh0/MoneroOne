import SwiftUI

struct BalanceCard: View {
    let balance: Decimal
    let unlockedBalance: Decimal
    let syncState: WalletManager.SyncState
    let connectionStage: ConnectionStage
    @ObservedObject var priceService: PriceService
    var isSyncBlocked: Bool = false
    var isOutsideTrustedZone: Bool = false
    var trustedLocationName: String? = nil
    var isTrustedLocationEnabled: Bool = false
    var onPriceChangeTap: (() -> Void)? = nil
    var onCardTap: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Calculate 24h price change from 1D chart data (same as chart views)
    private var priceChange24h: Double? {
        guard let dayData = priceService.chartDataCache["1D"],
              dayData.count >= 2,
              let firstPrice = dayData.first?.price,
              let lastPrice = dayData.last?.price,
              firstPrice > 0 else { return nil }
        return ((lastPrice - firstPrice) / firstPrice) * 100
    }

    private func formatPriceChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if isSyncBlocked {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Paused")
                        .font(.caption)
                        .foregroundColor(.red)
                        .accessibilityLabel("Sync status: paused")
                } else if case .synced = syncState {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Synced")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Sync status: synced")
                } else if case .error(let msg) = syncState {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Error: \(msg)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .accessibilityLabel("Sync error: \(msg)")
                } else {
                    ConnectionStepIndicator(
                        stage: connectionStage,
                        syncProgress: syncProgress
                    )
                }
                Spacer()

                // Price change indicator (tappable)
                if let change = priceChange24h {
                    Button {
                        onPriceChangeTap?()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2)
                            Text(formatPriceChange(change))
                                .font(.caption)
                        }
                        .foregroundColor(change >= 0 ? .green : .red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((change >= 0 ? Color.green : Color.red).opacity(0.1))
                        .cornerRadius(8)
                    }
                    .accessibilityLabel("24 hour price change: \(formatPriceChange(change))")
                    .accessibilityHint("Opens the price chart")
                }
            }

            HStack(spacing: 16) {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())
                    .accessibilityHidden(true)

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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Balance: \(XMRFormatter.format(balance)) XMR\(priceService.formatFiatValue(balance).map { ", approximately \($0)" } ?? "")")

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

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text("Locked until recent transactions confirm")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Available balance: \(XMRFormatter.format(unlockedBalance)) XMR\(priceService.formatFiatValue(unlockedBalance).map { ", approximately \($0)" } ?? ""). Some funds locked until recent transactions confirm.")
            }

            // Sync Progress (hidden when blocked)
            if !isSyncBlocked, case .syncing(let progress, let remaining) = syncState {
                VStack(spacing: 4) {
                    ProgressView(value: progress / 100)
                        .tint(.orange)
                        .accessibilityHidden(true)
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sync progress: \(Int(progress)) percent\(remaining.map { ", \(formatBlockCount($0)) blocks remaining" } ?? "")")
            }

            // Trusted location status
            if isSyncBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Sync paused — outside trusted zone")
                        .font(.caption)
                }
                .foregroundColor(.red)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: sync paused, outside trusted zone")
            } else if isOutsideTrustedZone {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Syncing from untrusted location")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: warning, syncing from untrusted location")
            } else if isTrustedLocationEnabled, let name = trustedLocationName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Syncing from \(name)")
                        .font(.caption)
                }
                .foregroundColor(.green)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location status: trusted, syncing from \(name)")
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
            HStack(spacing: 0) {
                ForEach(0..<stageCount, id: \.self) { index in
                    stepDot(for: index)

                    if index < stageCount - 1 {
                        stepLine(for: index)
                    }
                }
            }
            .accessibilityHidden(true)

            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(statusText)")
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
