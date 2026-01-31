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
                    } else if context.state.isConnecting {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.orange)
                            .font(.title3)
                    } else {
                        Text("\(Int(context.state.progress))%")
                            .font(.title2.bold())
                            .foregroundColor(.orange)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.state.isSynced {
                        Text("Synced")
                            .font(.headline)
                    } else if context.state.isConnecting {
                        Text("Connecting")
                            .font(.headline)
                    } else {
                        Text("Syncing Wallet")
                            .font(.headline)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isSynced {
                        Text("Updated \(context.state.lastUpdated, style: .relative) ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if context.state.isConnecting {
                        EmptyView()
                    } else {
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
                Image("MoneroSymbol")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
            } compactTrailing: {
                if context.state.isSynced {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else if context.state.isConnecting {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.orange)
                        .font(.caption)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                            .font(.caption2)

                        Text("\(Int(context.state.progress))%")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                }
            } minimal: {
                if context.state.isSynced {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if context.state.isConnecting {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.orange)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.orange)
                }
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
                if context.state.isSynced {
                    Text("Wallet Synced")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("Updated \(context.state.lastUpdated, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if context.state.isConnecting {
                    Text("Connecting")
                        .font(.headline)
                        .foregroundColor(.primary)
                } else {
                    Text("Syncing Wallet")
                        .font(.headline)
                        .foregroundColor(.primary)

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
            } else if context.state.isConnecting {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundColor(.orange)
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
