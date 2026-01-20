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
            }
        }
        .padding()
        .background(type.color.opacity(0.1))
        .cornerRadius(12)
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

struct WalletPreparingBanner: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing wallet for sending...")
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Text("\(Int(progress))% complete")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
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

        WalletPreparingBanner(progress: 45)
    }
    .padding()
}
