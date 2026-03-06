import SwiftUI

struct WalletManagerSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    private var truncatedAddress: String {
        let addr = walletManager.primaryAddress
        guard addr.count > 16 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(8))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Active wallet card
                Button {} label: {
                    HStack(spacing: 14) {
                        Image("MoneroSymbol")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .scaleEffect(1.15)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("Personal Wallet")
                                    .font(.headline)

                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Text("\(XMRFormatter.format(walletManager.balance)) XMR")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)

                            Text(truncatedAddress)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }

                        Spacer()
                    }
                    .padding(16)
                }
                .glassButtonStyle()
                .allowsHitTesting(false)

                // Add wallet (coming soon)
                Button {} label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                                .frame(width: 44, height: 44)

                            Image(systemName: "plus")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Text("Add Wallet")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("Coming Soon")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                    .padding(16)
                }
                .glassButtonStyle()
                .allowsHitTesting(false)
                .opacity(0.7)

                Spacer()
            }
            .padding()
            .navigationTitle("Wallets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}

#Preview {
    WalletManagerSheet()
        .environmentObject(WalletManager())
}
