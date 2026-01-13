import SwiftUI
import CoreImage.CIFilterBuiltins

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Receive XMR")
                    .font(.title2)
                    .fontWeight(.bold)

                // QR Code
                if !walletManager.address.isEmpty {
                    QRCodeView(content: walletManager.address)
                        .frame(width: 200, height: 200)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 200, height: 200)
                        .cornerRadius(16)
                        .overlay {
                            Text("No address")
                                .foregroundColor(.secondary)
                        }
                }

                // Address
                VStack(spacing: 8) {
                    Text("Your Address")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(walletManager.address.isEmpty ? "Loading..." : walletManager.address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Copy Button
                Button {
                    UIPasteboard.general.string = walletManager.address
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy Address")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal)
                .disabled(walletManager.address.isEmpty)

                Spacer()
            }
            .padding(.top, 24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
}
