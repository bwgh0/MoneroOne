import SwiftUI

struct WalletSwitcherButton: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) {
                isExpanded.toggle()
            }
        } label: {
            if isExpanded {
                expandedLabel
            } else {
                collapsedLabel
            }
        }
        .glassButtonStyle()
    }

    // MARK: - Collapsed

    private var collapsedLabel: some View {
        Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundStyle(.orange)
            .frame(width: 44, height: 44)
    }

    // MARK: - Expanded (current wallet card)

    private var truncatedAddress: String {
        let addr = walletManager.primaryAddress
        guard addr.count > 16 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(8))"
    }

    private var expandedLabel: some View {
        HStack(spacing: 14) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .scaleEffect(1.15)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Personal Wallet")
                    .font(.subheadline.weight(.semibold))

                Text("\(XMRFormatter.format(walletManager.balance)) XMR")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                Text(truncatedAddress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

/// A single inactive wallet row
private struct WalletRow: View {
    let name: String
    let balance: Decimal
    let address: String

    private var truncated: String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))...\(address.suffix(8))"
    }

    var body: some View {
        Button {} label: {
            HStack(spacing: 14) {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())
                    .opacity(0.7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))

                    Text("\(XMRFormatter.format(balance)) XMR")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)

                    Text(truncated)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }

                Spacer()

                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .glassButtonStyle()
        .padding(.horizontal)
    }
}

/// Additional wallet rows that appear when wallet manager is expanded
struct WalletManagerRows: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Future: additional wallet rows will go here
        }
    }
}

#Preview {
    @Previewable @State var expanded = false
    VStack {
        HStack(spacing: 0) {
            if !expanded {
                Text("Good evening")
                    .font(.title2.weight(.semibold))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Spacer(minLength: 12)
            }
            WalletSwitcherButton(isExpanded: $expanded)
                .environmentObject(WalletManager())
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        .animation(.snappy(duration: 0.35), value: expanded)
        .padding()
        Spacer()
    }
}
