import SwiftUI

struct DisclaimerView: View {
    @Binding var hasAcceptedDisclaimer: Bool

    @State private var hasScrolledToBottom = false
    @State private var checkboxes: [Bool] = [false, false, false, false, false]

    private var allChecked: Bool {
        checkboxes.allSatisfy { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("Important Information")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("disclaimer.title")

                Text("Please read and acknowledge before continuing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DisclaimerItem(
                        icon: "key.fill",
                        iconColor: .orange,
                        title: "You Control Your Keys",
                        description: "Monero One is a self-custody wallet. Your seed phrase is the only way to access your funds. We cannot recover it for you.",
                        isChecked: $checkboxes[0]
                    )
                    .accessibilityIdentifier("disclaimer.checkbox.0")

                    DisclaimerItem(
                        icon: "arrow.uturn.backward.circle.fill",
                        iconColor: .red,
                        title: "Transactions Are Irreversible",
                        description: "Once a Monero transaction is confirmed, it cannot be reversed, canceled, or modified. Always verify addresses before sending.",
                        isChecked: $checkboxes[1]
                    )
                    .accessibilityIdentifier("disclaimer.checkbox.1")

                    DisclaimerItem(
                        icon: "doc.text.fill",
                        iconColor: .blue,
                        title: "Protect Your Seed Phrase",
                        description: "If you lose your 16-word seed phrase, your funds are permanently lost. Write it down and store it securely offline.",
                        isChecked: $checkboxes[2]
                    )
                    .accessibilityIdentifier("disclaimer.checkbox.2")

                    DisclaimerItem(
                        icon: "chart.line.uptrend.xyaxis",
                        iconColor: .purple,
                        title: "Cryptocurrency Is Volatile",
                        description: "The value of Monero can fluctuate significantly. Only use funds you can afford to lose.",
                        isChecked: $checkboxes[3]
                    )
                    .accessibilityIdentifier("disclaimer.checkbox.3")

                    DisclaimerItem(
                        icon: "checkmark.shield.fill",
                        iconColor: .green,
                        title: "No Warranty",
                        description: "This software is provided as-is. While we strive for security and reliability, we cannot guarantee the software is free of bugs.",
                        isChecked: $checkboxes[4]
                    )
                    .accessibilityIdentifier("disclaimer.checkbox.4")
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }

            // Bottom button
            VStack(spacing: 12) {
                Divider()

                Button {
                    withAnimation {
                        hasAcceptedDisclaimer = true
                        UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
                    }
                } label: {
                    Text("I Understand, Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(allChecked ? Color.orange : Color.gray.opacity(0.5))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(!allChecked)
                .accessibilityIdentifier("disclaimer.acceptButton")
                .padding(.horizontal)
                .padding(.bottom)
            }
            .background(Color(.systemBackground))
        }
    }
}

struct DisclaimerItem: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    @Binding var isChecked: Bool

    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // Checkbox
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundColor(isChecked ? .orange : .secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundColor(iconColor)
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                    }

                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .frame(minHeight: 100)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DisclaimerView(hasAcceptedDisclaimer: .constant(false))
}
