import SwiftUI

struct WalletSwitcherButton: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager
    @State private var currentPage = 0

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) {
                if isExpanded {
                    isExpanded = false
                    currentPage = 0
                } else {
                    isExpanded = true
                }
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

    // MARK: - Expanded (vertical carousel)

    private var expandedLabel: some View {
        VStack(spacing: 0) {
            // Card content area
            TabView(selection: $currentPage) {
                walletCard
                    .tag(0)

                addWalletCard
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 88)

            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<2) { index in
                    Circle()
                        .fill(index == currentPage ? Color.orange : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var walletCard: some View {
        HStack(spacing: 14) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .scaleEffect(1.15)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Personal Wallet")
                        .font(.subheadline.weight(.semibold))

                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Text("\(XMRFormatter.format(walletManager.balance)) XMR")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }

    private var addWalletCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.4))

            VStack(alignment: .leading, spacing: 4) {
                Text("Add Wallet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("Coming Soon")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .opacity(0.6)
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
