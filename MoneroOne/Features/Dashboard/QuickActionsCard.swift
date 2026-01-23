import SwiftUI

/// Quick action buttons card for iPad Command Center
struct QuickActionsCard: View {
    let onSend: () -> Void
    let onReceive: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
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
