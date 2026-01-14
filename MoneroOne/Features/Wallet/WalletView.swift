import SwiftUI

struct WalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var showReceive = false
    @State private var showSend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Testnet Banner
                    if walletManager.isTestnet {
                        TestnetBanner()
                            .padding(.horizontal)
                    }

                    // Error Banners
                    VStack(spacing: 8) {
                        OfflineBanner()
                        SyncErrorBanner(syncState: walletManager.syncState) {
                            walletManager.refresh()
                        }
                    }
                    .padding(.horizontal)
                    .animation(.easeInOut, value: walletManager.syncState)

                    // Balance Card
                    BalanceCard(
                        balance: walletManager.balance,
                        unlockedBalance: walletManager.unlockedBalance,
                        syncState: walletManager.syncState,
                        priceService: priceService
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
            .refreshable {
                walletManager.refresh()
                await priceService.fetchPrice()
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView()
            }
            .sheet(isPresented: $showSend) {
                SendView()
            }
        }
    }
}

struct TestnetBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "flask.fill")
                .foregroundStyle(.white)
            Text("Testnet Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("Test XMR only")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cyan.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .font(.system(size: 28))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .buttonStyle(.glass)
    }
}

#Preview {
    WalletView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}
