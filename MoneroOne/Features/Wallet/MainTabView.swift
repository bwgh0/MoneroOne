import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var selectedTab: Tab = .wallet

    enum Tab {
        case wallet
        case transactions
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            WalletView()
                .tabItem {
                    Label("Wallet", systemImage: "wallet.pass")
                }
                .tag(Tab.wallet)

            TransactionListView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(Tab.transactions)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(WalletManager())
}
