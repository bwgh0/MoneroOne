import SwiftUI

/// Who Send pays: an address, or a payment link anyone can claim
/// (Features/PaymentLinks).
enum SendRecipientMode: Hashable, CaseIterable {
    case address
    case link
}

struct SendAddressStep: View {
    @Binding var recipientAddress: String
    @Binding var showScanner: Bool
    /// The Address | Link control at the top of the step.
    @Binding var mode: SendRecipientMode
    let isConnected: Bool
    let isValidAddress: Bool
    let onContinue: () -> Void

    @State private var showContent = false

    var body: some View {
        VStack(spacing: 0) {
            modePicker
                .padding(.horizontal)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: String(localized: "No internet connection. Cannot send."),
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

                    // The segment's content cross-fades in place.
                    ZStack(alignment: .top) {
                        switch mode {
                        case .address:
                            addressContent
                                .transition(.opacity)
                        case .link:
                            PaymentLinkRecipientCard()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: mode)
                }
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
            .accessibilityHint(canContinue || mode == .link ? "Proceed to enter amount" : "Enter a valid address first")
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

    private var modePicker: some View {
        GlassSegmentedPicker(
            selection: $mode,
            accessibilityHint: { mode in
                mode == .link ? String(localized: "Send money as a link anyone can claim") : nil
            }
        ) { mode in
            switch mode {
            case .address: String(localized: "Address", comment: "Send: pay an address")
            case .link: String(localized: "Link", comment: "Send: pay with a payment link")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("send.modePicker")
    }

    private var addressContent: some View {
        VStack(spacing: 24) {
            // Address field
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipient Address")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Enter XMR address", text: $recipientAddress)
                        .font(.system(.caption, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("send.addressField")
                        .accessibilityLabel("Recipient address")

                    if !recipientAddress.isEmpty {
                        Button {
                            recipientAddress = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear address")
                    }
                }
                .padding()
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

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    showScanner = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .glassButtonStyle()
                .accessibilityLabel("Scan QR code")

                Button {
                    if let clipboard = UIPasteboard.general.string {
                        recipientAddress = clipboard
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .glassButtonStyle()
                .accessibilityLabel("Paste address from clipboard")
            }
        }
    }

    /// A link needs no address: it can go on as soon as Send can.
    private var canContinue: Bool {
        isConnected && (mode == .link || isValidAddress)
    }
}
