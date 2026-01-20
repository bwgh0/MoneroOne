import SwiftUI

struct SendConfirmationView: View {
    let amount: Decimal
    let fee: Decimal
    let address: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var total: Decimal {
        amount + fee
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header with proper spacing for sheet drag indicator
            Spacer()
                .frame(height: 8)

            Text("Confirm Send")
                .font(.title2.weight(.semibold))

            // Details
            VStack(spacing: 16) {
                // Amount
                HStack {
                    Text("Amount")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(formatXMR(amount)) XMR")
                        .fontWeight(.medium)
                }

                Divider()

                // Network Fee
                HStack {
                    Text("Network Fee")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(formatXMR(fee)) XMR")
                        .fontWeight(.medium)
                }

                Divider()

                // Total
                HStack {
                    Text("Total")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(formatXMR(total)) XMR")
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Recipient
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipient")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(formatAddress(address))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                Button {
                    onConfirm()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.callout.weight(.semibold))
                        Text("Confirm Send")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.glass)

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func formatXMR(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 12
        return formatter.string(from: value as NSDecimalNumber) ?? "0.0000"
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 20 else { return addr }
        return "\(addr.prefix(16))...\(addr.suffix(12))"
    }
}

#Preview {
    SendConfirmationView(
        amount: Decimal(string: "0.5")!,
        fee: Decimal(string: "0.000042")!,
        address: "888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H",
        onConfirm: {},
        onCancel: {}
    )
}
