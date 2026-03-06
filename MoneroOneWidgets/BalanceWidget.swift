import SwiftUI
import WidgetKit
import os.log

private let widgetLog = OSLog(subsystem: "one.monero.MoneroOne.WidgetsExtension", category: "Balance")

struct BalanceWidget: Widget {
    let kind = "BalanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceProvider()) { entry in
            if #available(iOS 17.0, *) {
                BalanceWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                BalanceWidgetView(entry: entry)
                    .padding()
                    .background(Color(.systemBackground))
            }
        }
        .configurationDisplayName("Balance")
        .description("View your Monero wallet balance and sync status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), data: WidgetDataManager.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        let data = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
        completion(BalanceEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        os_log("getTimeline called", log: widgetLog, type: .info)
        let data = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
        os_log("Using data with isEnabled=%d", log: widgetLog, type: .info, data.isEnabled ? 1 : 0)
        let entry = BalanceEntry(date: Date(), data: data)

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct BalanceEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: BalanceEntry

    var body: some View {
        if !entry.data.isEnabled {
            disabledView
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }

    private var disabledView: some View {
        VStack(spacing: 8) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .scaleEffect(1.15)
                .clipShape(Circle())

            Text("Monero One")
                .font(.headline.weight(.semibold))

            Text("Enable in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())

                Spacer()

                Image(systemName: entry.data.syncStatus.iconName)
                    .font(.caption2)
                    .foregroundColor(statusColor)
            }

            Spacer()

            // Balance
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.data.balanceFormatted)
                    .font(.system(.title3, design: .rounded).bold())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Text("XMR")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let fiat = entry.data.fiatBalance {
                Text(fiat)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if entry.data.isTestnet {
                Text("TESTNET")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
    }

    private var mediumView: some View {
        HStack(spacing: 12) {
            // Left side - Balance
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image("MoneroSymbol")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 26, height: 26)
                        .clipShape(Circle())
                        .scaleEffect(1.15)
                        .clipShape(Circle())

                    Text("Monero One")
                        .font(.subheadline.weight(.semibold))

                    if entry.data.isTestnet {
                        Text("TESTNET")
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.data.balanceFormatted)
                        .font(.system(.title2, design: .rounded).bold())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("XMR")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let fiat = entry.data.fiatBalance {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(fiat)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Right side - Status
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: entry.data.syncStatus.iconName)
                        .font(.caption2)
                    Text(entry.data.syncStatus.displayText)
                        .font(.caption2)
                }
                .foregroundColor(statusColor)

                Spacer()

                Text("Updated")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(entry.data.lastUpdated, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch entry.data.syncStatus {
        case .synced: return .green
        case .syncing, .connecting: return .orange
        case .offline: return .red
        }
    }
}

struct BalanceWidget_Previews: PreviewProvider {
    static var previews: some View {
        BalanceWidgetView(entry: BalanceEntry(date: Date(), data: WidgetDataManager.placeholder))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
        BalanceWidgetView(entry: BalanceEntry(date: Date(), data: WidgetDataManager.placeholder))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
