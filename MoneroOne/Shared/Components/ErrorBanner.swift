import SwiftUI

struct ErrorBanner: View {
    let message: String
    let type: BannerType
    var retryAction: (() -> Void)?

    enum BannerType {
        case offline
        case error
        case warning

        var icon: String {
            switch self {
            case .offline: return "wifi.slash"
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .offline: return .gray
            case .error: return .red
            case .warning: return .orange
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.icon)
                .font(.body)
                .foregroundColor(type.color)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            if let retryAction = retryAction {
                Button {
                    retryAction()
                } label: {
                    Text("Retry")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(type.color)
                }
                .accessibilityLabel("Retry")
                .accessibilityHint("Attempt to resolve: \(message)")
            }
        }
        .padding()
        .background(type.color.opacity(0.1))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(type == .error ? "Error" : type == .warning ? "Warning" : "Offline"): \(message)")
    }
}

struct OfflineBanner: View {
    @ObservedObject var networkMonitor = NetworkMonitor.shared

    var body: some View {
        if !networkMonitor.isConnected {
            ErrorBanner(
                message: "No internet connection",
                type: .offline
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Shown after a seed restore that synced with no history: the restore
/// height was probably too recent. Points at Settings › Sync Settings.
struct RestoreHeightHintBanner: View {
    let restoreHeight: UInt64
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("No transactions found since block \(restoreHeight.formatted())")
                    .font(.subheadline.weight(.semibold))
                Text("If this wallet is older, lower the restore height in Settings › Sync Settings and reset the sync data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct SyncErrorBanner: View {
    let syncState: WalletManager.SyncState
    var retryAction: (() -> Void)?

    var body: some View {
        if case .error(let message) = syncState {
            ErrorBanner(
                message: "Sync error: \(message)",
                type: .error,
                retryAction: retryAction
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview("Error Banner") {
    VStack(spacing: 16) {
        ErrorBanner(
            message: "No internet connection",
            type: .offline
        )

        ErrorBanner(
            message: "Failed to sync wallet",
            type: .error,
            retryAction: { }
        )

        ErrorBanner(
            message: "Price data unavailable",
            type: .warning,
            retryAction: { }
        )
    }
    .padding()
}
