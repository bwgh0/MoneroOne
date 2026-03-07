import SwiftUI

struct SendStatusStep: View {
    let phase: SendFlowPhase
    let amountString: String
    let priceService: PriceService
    let onDone: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var showContent = false
    @State private var copiedHash = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status visual
            ZStack {
                switch phase {
                case .sending:
                    GradientSpinner()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))

                case .success:
                    SuccessCheckmarkView()
                        .transition(.scale(scale: 0.2).combined(with: .opacity))

                case .error:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.red)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))

                default:
                    EmptyView()
                }
            }
            .frame(height: 160)

            // Status text
            VStack(spacing: 12) {
                switch phase {
                case .sending:
                    Text("Sending Transaction...")
                        .font(.title2.weight(.semibold))

                    Text("Please wait while your transaction is being broadcast")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                case .success(let txHash):
                    Text("Sent!")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.green)

                    // Amount + fiat
                    VStack(spacing: 4) {
                        if let amount = Decimal(string: amountString) {
                            Text("\(XMRFormatter.format(amount)) XMR")
                                .font(.title3.weight(.semibold))

                            if let fiat = priceService.formatFiatValue(amount) {
                                Text("≈ \(fiat)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // TX hash pill
                    Button {
                        UIPasteboard.general.string = txHash
                        copiedHash = true
                        HapticFeedback.shared.softTick()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedHash = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedHash ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                            Text(copiedHash ? "Copied!" : formatHash(txHash))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(copiedHash ? .green : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel(copiedHash ? "Transaction ID copied" : "Copy transaction ID")
                    .accessibilityHint("Copies the full transaction ID to clipboard")

                case .error(let message):
                    Text("Transaction Failed")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.red)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                default:
                    EmptyView()
                }
            }
            .opacity(showContent ? 1 : 0)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                switch phase {
                case .sending:
                    EmptyView()

                case .success:
                    Button(action: onDone) {
                        Text("Done")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Done")

                case .error:
                    Button(action: onRetry) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Retry transaction")

                    Button(action: onClose) {
                        Text("Close")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .accessibilityLabel("Close")

                default:
                    EmptyView()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                showContent = true
            }
        }
        .onChange(of: phase) { _ in
            // Reset and re-animate text when transitioning (e.g. sending → success)
            showContent = false
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                showContent = true
            }
        }
    }

    private func formatHash(_ hash: String) -> String {
        guard hash.count > 20 else { return hash }
        return "\(hash.prefix(10))...\(hash.suffix(6))"
    }
}
