import SwiftUI

struct SendAddressStep: View {
    @Binding var recipientAddress: String
    @Binding var showScanner: Bool
    let isConnected: Bool
    let isValidAddress: Bool
    let onContinue: () -> Void

    @State private var showContent = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: "No internet connection. Cannot send.",
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

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
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
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
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .glassButtonStyle()
                        .accessibilityLabel("Paste address from clipboard")
                    }
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
                .foregroundStyle(canContinue ? .orange : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canContinue)
            .padding()
            .accessibilityLabel("Continue")
            .accessibilityHint(canContinue ? "Proceed to enter amount" : "Enter a valid address first")
        }
        .navigationTitle("Send XMR")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
    }

    private var canContinue: Bool {
        isConnected && isValidAddress
    }
}
