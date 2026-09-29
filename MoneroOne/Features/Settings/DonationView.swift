import SwiftUI
import UIKit

struct DonationView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false

    private let donationAddress = "86AWuSFkMKCNp4e7dWho3CBvFpvAzj8hnZNWM9fedD5LKb2mXVfnmH9XuDD9zYqzzR6LAFxUSsdGTVUDABzcgjMfFVfBHpP"

    var body: some View {
        QRFocusContainer { focus in
            content(focus: focus)
        }
        .navigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(focus: QRFocus) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.largeTitle)
                        .foregroundColor(.brand)

                    Text("Support Development")
                        .font(.title2.weight(.semibold))
                }
                .padding(.top, 16)
                .qrFocusRecede(focus, toward: .top)

                // QR Code: a tap grows it into focus mode.
                FocusableQRPlate(
                    item: QRFocusItem(content: "monero:\(donationAddress)", title: String(localized: "Donate")),
                    side: 240,
                    focus: focus
                )

                Group {
                    addressCard
                    actionButtons
                }
                .qrFocusRecede(focus, toward: .bottom)

                Spacer(minLength: 40)
            }
        }
    }

    private var addressCard: some View {
        VStack(spacing: 12) {
            Text("Monero Address")
                .font(.caption)
                .foregroundColor(.secondary)

            CodeText(donationAddress, color: .label, alignment: .center, selectable: true)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Copy Button (glass, so the pair matches)
            Button {
                copyAddress()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    Text(copied ? "Copied!" : "Copy")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(copied ? Color.green : Color.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()

            // Send Button, gated on canSend: `isViewOnly` is true for a
            // hardware wallet too, and its device signs the send.
            Button {
                walletManager.prefillSendAddress = donationAddress
                walletManager.prefillSendAmount = "0.25"
                walletManager.shouldShowSendView = true
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("Send XMR")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(walletManager.canSend ? Color.brand : Color.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!walletManager.canSend)
            .accessibilityLabel(walletManager.canSend ? "Send XMR" : "Send XMR, disabled for view-only wallet")
            .accessibilityHint(walletManager.canSend ? "Prefills send screen with donation address" : "This wallet is view-only and cannot send")
        }
        .padding(.horizontal)
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
