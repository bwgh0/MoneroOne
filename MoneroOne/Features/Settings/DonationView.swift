import SwiftUI
import UIKit

struct DonationView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false

    private let donationAddress = "86AWuSFkMKCNp4e7dWho3CBvFpvAzj8hnZNWM9fedD5LKb2mXVfnmH9XuDD9zYqzzR6LAFxUSsdGTVUDABzcgjMfFVfBHpP"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.largeTitle)
                        .foregroundColor(.orange)

                    Text("Support Development")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("If you enjoy MoneroOne, consider donating to support continued development.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 16)

                // QR Code
                QRCodeView(content: "monero:\(donationAddress)")
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.1), radius: 10)

                // Address Card
                VStack(spacing: 12) {
                    Text("Monero Address")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(donationAddress)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Action Buttons
                HStack(spacing: 16) {
                    // Copy Button
                    Button {
                        copyAddress()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy")
                                .fontWeight(.medium)
                        }
                        .foregroundColor(copied ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(copied ? Color.green.opacity(0.2) : Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    // Send Button
                    Button {
                        walletManager.prefillSendAddress = donationAddress
                        walletManager.prefillSendAmount = "0.25"
                        walletManager.shouldShowSendView = true
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Send XMR")
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [.pink, .orange, .yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
        .navigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyAddress() {
        UIPasteboard.general.string = donationAddress
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

#Preview {
    NavigationStack {
        DonationView()
    }
}
