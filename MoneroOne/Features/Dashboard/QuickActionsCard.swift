import SwiftUI

/// Quick action buttons card for iPad Command Center
struct QuickActionsCard: View {
    let onSend: () -> Void
    let onReceive: () -> Void
    var isSendDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                title: "Send",
                icon: "arrow.up.circle.fill",
                color: .orange,
                isDisabled: isSendDisabled,
                action: onSend
            )

            QuickActionButton(
                title: "Receive",
                icon: "arrow.down.circle.fill",
                color: .green,
                action: onReceive
            )
        }
    }
}

/// Individual quick action button
struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.6) : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityLabel(isDisabled ? "\(title), disabled for view-only wallet" : title)
        .accessibilityHint(isDisabled ? "This wallet is view-only and cannot send" : "Double tap to \(title.lowercased()) Monero")
    }
}

#Preview {
    QuickActionsCard(
        onSend: {},
        onReceive: {}
    )
    .padding()
}
