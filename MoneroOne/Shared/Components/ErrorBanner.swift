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
            case .error: return "exclamationmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .offline: return .gray
            case .error: return .red
            case .warning: return .yellow
            }
        }

        /// Caution yellow needs a stronger tint than gray or red to show.
        var fill: Color {
            color.opacity(self == .warning ? 0.15 : 0.1)
        }

        /// Yellow is never a text color, so a warning's Retry uses the label color.
        var actionColor: Color {
            self == .warning ? .primary : color
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
                        .foregroundColor(type.actionColor)
                }
                .accessibilityLabel("Retry")
                .accessibilityHint("Attempt to resolve: \(message)")
            }
        }
        .padding()
        .background(type.fill)
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(type == .error ? String(localized: "Error") : type == .warning ? String(localized: "Warning") : String(localized: "Offline")): \(message)")
    }
}

struct OfflineBanner: View {
    @ObservedObject var networkMonitor = NetworkMonitor.shared

    var body: some View {
        if !networkMonitor.isConnected {
            ErrorBanner(
                message: String(localized: "No internet connection"),
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
                message: String(localized: "Sync error: \(message)"),
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
