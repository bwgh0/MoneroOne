import SwiftUI
import WidgetKit

struct WidgetSettingsView: View {
    @AppStorage("widgetEnabled") private var widgetEnabled = false
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        List {
            Section {
                Toggle(isOn: $widgetEnabled) {
                    Text("Show Balance & Transactions")
                }
                .onChange(of: widgetEnabled) { enabled in
                    // Reload once the file is written.
                    walletManager.saveWidgetData(enabled: enabled) {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                .onAppear {
                    // Ensure widget data exists if widget is already enabled
                    if widgetEnabled {
                        walletManager.saveWidgetData(enabled: true) {
                            WidgetCenter.shared.reloadAllTimelines()
                        }
                    }
                }
            } footer: {
                Text("The Price widget works without this.")
            }
        }
        .navigationTitle("Widget")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        WidgetSettingsView()
            .environmentObject(WalletManager())
    }
}
