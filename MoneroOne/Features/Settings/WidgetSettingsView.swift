import SwiftUI
import WidgetKit

struct WidgetSettingsView: View {
    @AppStorage("widgetEnabled") private var widgetEnabled = false
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        List {
            Section {
                Toggle(isOn: $widgetEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Widget")
                        Text("Show balance on home screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: widgetEnabled) { enabled in
                    // Save synchronously before reloading
                    walletManager.saveWidgetData(enabled: enabled)

                    // Small delay to ensure file system sync before widget reads
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                .onAppear {
                    // Ensure widget data exists if widget is already enabled
                    if widgetEnabled {
                        walletManager.saveWidgetData(enabled: true)
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            } footer: {
                Text("Add the MoneroOne widget to your home screen to see your balance at a glance.")
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
