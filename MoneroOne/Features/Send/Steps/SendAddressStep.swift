import SwiftUI

struct SendAddressStep: View {
    @Binding var recipientAddress: String
    @Binding var showScanner: Bool
    /// A payment link (Features/PaymentLinks) is the recipient instead of
    /// an address. The typed address stays, so ✕ on the token brings it back.
    @Binding var isLinkMode: Bool
    let isConnected: Bool
    let isValidAddress: Bool
    let onContinue: () -> Void

    @State private var showContent = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: String(localized: "No internet connection. Cannot send."),
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

                    recipient

                    actionButtons
                }
                // Only the recipient changes: the field and the token
                // cross-fade in place.
                .animation(.easeInOut(duration: 0.35), value: isLinkMode)
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Continue button
            Button(action: onContinue) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canContinue ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canContinue)
            .padding()
            .accessibilityLabel("Continue")
            .accessibilityHint(canContinue || isLinkMode ? "Proceed to enter amount" : "Enter a valid address first")
        }
        .navigationTitle("Send XMR")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    /// The "Recipient" label over the address field, or over the link token.
    private var recipient: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipient")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ZStack {
                if isLinkMode {
                    PaymentLinkRecipientToken {
                        isLinkMode = false
                    }
                    .transition(.opacity)
                } else {
                    addressField
                        .transition(.opacity)
                }
            }
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Enter XMR address", text: $recipientAddress)
                    .font(.system(.caption, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("send.addressField")
                    .accessibilityLabel("Recipient")

                if !recipientAddress.isEmpty {
                    Button {
                        recipientAddress = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            // The link token has the same height, so the buttons stay put.
            .frame(minHeight: 54)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Validation indicator
            if !recipientAddress.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isValidAddress ? .green : .red)
                    Text(isValidAddress ? "Valid address" : "Invalid address")
                        .font(.caption)
                        .foregroundStyle(isValidAddress ? .green : .red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(isValidAddress ? "Valid address" : "Invalid address")
            }
        }
    }

    /// Scan QR, Paste and Link: the three ways to fill the recipient. They
    /// stack at accessibility text sizes, or when a label would not fit.
    private var actionButtons: some View {
        RecipientButtonsLayout(alwaysStacks: dynamicTypeSize.isAccessibilitySize) {
            Button {
                showScanner = true
            } label: {
                actionLabel("Scan QR", systemImage: "qrcode.viewfinder")
            }
            .glassButtonStyle()
            .accessibilityLabel("Scan QR code")

            Button {
                if let clipboard = UIPasteboard.general.string {
                    isLinkMode = false
                    recipientAddress = clipboard
                }
            } label: {
                actionLabel("Paste", systemImage: "doc.on.clipboard")
            }
            .glassButtonStyle()
            .accessibilityLabel("Paste address from clipboard")

            Button {
                isLinkMode = true
            } label: {
                actionLabel("Link", systemImage: "link", isOn: !isLinkMode)
            }
            .glassButtonStyle()
            .disabled(isLinkMode)
            .accessibilityLabel("Link")
            .accessibilityHint("Sends the money as a link anyone can claim")
            .accessibilityAddTraits(isLinkMode ? .isSelected : [])
            .accessibilityIdentifier("send.linkButton")
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, isOn: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(isOn ? .brand : .gray)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// A link needs no address: it can go on as soon as Send can.
    private var canContinue: Bool {
        isConnected && (isLinkMode || isValidAddress)
    }
}

/// Equal capsules in one row with a 12 gutter, or one column when the
/// widest label does not fit its share of the row.
private struct RecipientButtonsLayout: Layout {
    var alwaysStacks = false
    var spacing: CGFloat = 12

    private func itemWidth(in width: CGFloat, count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    private func fitsInRow(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard !alwaysStacks, subviews.count > 1 else { return false }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let width else { return true }
        return widest <= itemWidth(in: width, count: subviews.count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        if fitsInRow(proposal.width, subviews) {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let width = proposal.width ?? widest * count + spacing * (count - 1)
            let item = itemWidth(in: width, count: subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: item, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * (count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if fitsInRow(bounds.width, subviews) {
            let item = itemWidth(in: bounds.width, count: subviews.count)
            var x = bounds.minX
            for subview in subviews {
                // Centered like an HStack: the Paste glyph runs a little taller.
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: item, height: nil))
                x += item + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }
}
