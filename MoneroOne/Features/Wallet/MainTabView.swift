import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @State private var selectedTab: Tab = .wallet

    enum Tab {
        case wallet
        case chart
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            WalletView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Wallet", systemImage: "wallet.pass")
                }
                .tag(Tab.wallet)

            PriceChartView()
                .tabItem {
                    Label("Chart", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(Tab.chart)

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
        .environmentObject(PriceService())
}
