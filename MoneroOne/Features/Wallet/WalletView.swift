import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showReceive = false
    @State private var showSend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance Card
                    BalanceCard(
                        balance: walletManager.balance,
                        unlockedBalance: walletManager.unlockedBalance,
                        syncState: walletManager.syncState
                    )
                    .padding(.horizontal)

                    // Action Buttons
                    HStack(spacing: 16) {
                        ActionButton(
                            title: "Send",
                            icon: "arrow.up.circle.fill",
                            color: .orange
                        ) {
                            showSend = true
                        }

                        ActionButton(
                            title: "Receive",
                            icon: "arrow.down.circle.fill",
                            color: .green
                        ) {
                            showReceive = true
                        }
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Monero One")
            .sheet(isPresented: $showReceive) {
                ReceiveView()
            }
            .sheet(isPresented: $showSend) {
                SendView()
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WalletView()
        .environmentObject(WalletManager())
}
