import SwiftUI

struct TransactionProgressView: View {
    enum TransactionState {
        case sending
        case success(txHash: String)
        case error(message: String)
    }

    let state: TransactionState
    let onDone: () -> Void
    let onRetry: (() -> Void)?

    @State private var showCheckmark = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status Icon
            ZStack {
                switch state {
                case .sending:
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.orange)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.green)
                        .scaleEffect(showCheckmark ? 1 : 0.5)
                        .opacity(showCheckmark ? 1 : 0)
                        .onAppear {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                                showCheckmark = true
                            }
                        }

                case .error:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.red)
                }
            }
            .frame(height: 100)

            // Status Text
            VStack(spacing: 12) {
                switch state {
                case .sending:
                    Text("Sending Transaction...")
                        .font(.title2.weight(.semibold))

                    Text("Please wait while your transaction is being broadcast")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                case .success(let txHash):
                    Text("Transaction Sent!")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.green)

                    VStack(spacing: 8) {
                        Text("Transaction ID")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(formatTxHash(txHash))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)

                        Button {
                            UIPasteboard.general.string = txHash
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }

                case .error(let message):
                    Text("Transaction Failed")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.red)

                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                switch state {
                case .sending:
                    EmptyView()

                case .success:
                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .glassButtonStyle()

                case .error:
                    if let onRetry = onRetry {
                        Button {
                            onRetry()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .glassButtonStyle()
                    }

                    Button {
                        onDone()
                    } label: {
                        Text("Close")
                            .font(.callout.weight(.medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.bottom)
        }
        .padding()
        .interactiveDismissDisabled(state.isSending)
    }

    private func formatTxHash(_ hash: String) -> String {
        guard hash.count > 20 else { return hash }
        return "\(hash.prefix(12))...\(hash.suffix(8))"
    }
}

extension TransactionProgressView.TransactionState {
    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }
}

#Preview("Sending") {
    TransactionProgressView(
        state: .sending,
        onDone: {},
        onRetry: nil
    )
}

#Preview("Success") {
    TransactionProgressView(
        state: .success(txHash: "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6"),
        onDone: {},
        onRetry: nil
    )
}

#Preview("Error") {
    TransactionProgressView(
        state: .error(message: "Network connection failed. Please check your internet and try again."),
        onDone: {},
        onRetry: {}
    )
}
