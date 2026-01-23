import SwiftUI

/// Quick action buttons card for iPad Command Center
struct QuickActionsCard: View {
    let onSend: () -> Void
    let onReceive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                title: "Send",
                icon: "arrow.up.circle.fill",
                color: .orange,
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
    }
}

#Preview {
    QuickActionsCard(
        onSend: {},
        onReceive: {}
    )
    .padding()
}
