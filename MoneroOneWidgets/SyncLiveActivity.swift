import SwiftUI
import WidgetKit
import ActivityKit

struct SyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            // Lock Screen / Banner UI
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    Image("MoneroSymbol")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isSynced {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    } else {
                        Text("\(Int(context.state.progress))%")
                            .font(.title2.bold())
                            .foregroundColor(.orange)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.isSynced ? "Synced" : "Syncing Wallet")
                        .font(.headline)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.isSynced {
                        VStack(spacing: 8) {
                            ProgressView(value: context.state.progress, total: 100)
                                .tint(.orange)

                            if let blocks = context.state.blocksRemaining, blocks > 0 {
                                Text("\(formatBlockCount(blocks)) blocks remaining")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.orange)
                    .symbolEffect(.rotate, isActive: !context.state.isSynced)
            } compactTrailing: {
                if context.state.isSynced {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("\(Int(context.state.progress))%")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }
            } minimal: {
                Image(systemName: context.state.isSynced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundColor(context.state.isSynced ? .green : .orange)
                    .symbolEffect(.rotate, isActive: !context.state.isSynced)
            }
        }
    }
}

// Helper to format block counts (e.g., 1500 -> "1.5K", 1500000 -> "1.50M")
private func formatBlockCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.2fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    } else {
        return "\(count)"
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<SyncActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            // Monero logo
            Image("MoneroSymbol")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.isSynced ? "Wallet Synced" : "Syncing Wallet")
                    .font(.headline)
                    .foregroundColor(.primary)

                if context.state.isSynced {
                    Text("Your wallet is up to date")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView(value: context.state.progress, total: 100)
                        .tint(.orange)

                    if let blocks = context.state.blocksRemaining, blocks > 0 {
                        Text("\(formatBlockCount(blocks)) blocks remaining")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if context.state.isSynced {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
            } else {
                Text("\(Int(context.state.progress))%")
                    .font(.title2.bold())
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .activityBackgroundTint(Color(.systemBackground))
    }
}

#Preview("Live Activity", as: .content, using: SyncActivityAttributes(walletName: "Monero One")) {
    SyncLiveActivity()
} contentStates: {
    SyncActivityAttributes.ContentState(progress: 45, blocksRemaining: 12500, isSynced: false, lastUpdated: Date())
    SyncActivityAttributes.ContentState(progress: 100, blocksRemaining: 0, isSynced: true, lastUpdated: Date())
}
