import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var selectedTab: Tab = .wallet

    enum Tab {
        case wallet
        case chart
        case settings
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad: TabView with CommandCenterView instead of WalletView
            iPadTabView
        } else {
            // iPhone: Keep existing TabView
            iPhoneTabView
        }
    }

    // MARK: - iPad Layout

    private var iPadTabView: some View {
        TabView(selection: $selectedTab) {
            CommandCenterView()
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }
                .tag(Tab.wallet)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneTabView: some View {
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
