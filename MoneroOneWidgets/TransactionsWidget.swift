import SwiftUI
import WidgetKit
import os.log

private let widgetLog = OSLog(subsystem: "one.monero.MoneroOne.WidgetsExtension", category: "Transactions")

struct TransactionsWidget: Widget {
    let kind = "TransactionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TransactionsProvider()) { entry in
            if #available(iOS 17.0, *) {
                TransactionsWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                TransactionsWidgetView(entry: entry)
                    .padding()
                    .background(Color(.systemBackground))
            }
        }
        .configurationDisplayName("Recent Activity")
        .description("View your balance and recent transactions.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TransactionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> TransactionsEntry {
        TransactionsEntry(date: Date(), data: WidgetDataManager.placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TransactionsEntry) -> Void) {
        let data = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
        completion(TransactionsEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TransactionsEntry>) -> Void) {
        os_log("getTimeline called", log: widgetLog, type: .info)
        let data = WidgetDataManager.shared.load() ?? WidgetDataManager.placeholder
        os_log("Using data with isEnabled=%d", log: widgetLog, type: .info, data.isEnabled ? 1 : 0)
        let entry = TransactionsEntry(date: Date(), data: data)

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct TransactionsEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct TransactionsWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TransactionsEntry

    var body: some View {
        if !entry.data.isEnabled {
            disabledView
        } else {
            switch family {
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView
            default:
                mediumView
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

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with balance
            HStack {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.data.balanceFormatted)
                        .font(.system(.subheadline, design: .rounded).bold())
                    HStack(spacing: 2) {
                        Text("XMR")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        if let fiat = entry.data.fiatBalance {
                            Text("•")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(fiat)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 3) {
                    Image(systemName: entry.data.syncStatus.iconName)
                        .font(.system(size: 9))
                    Text(entry.data.syncStatus.displayText)
                        .font(.system(size: 9))
                }
                .foregroundColor(statusColor)
            }

            Divider()

            // Recent transactions (1-2)
            if entry.data.recentTransactions.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No recent transactions")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(entry.data.recentTransactions.prefix(2)) { tx in
                    transactionRow(tx)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image("MoneroSymbol")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .scaleEffect(1.15)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
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

                    HStack(spacing: 3) {
                        Image(systemName: entry.data.syncStatus.iconName)
                            .font(.system(size: 9))
                        Text(entry.data.syncStatus.displayText)
                            .font(.system(size: 9))
                    }
                    .foregroundColor(statusColor)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.data.balanceFormatted)
                        .font(.system(.title3, design: .rounded).bold())
                    HStack(spacing: 4) {
                        Text("XMR")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let fiat = entry.data.fiatBalance {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(fiat)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()

            // Section header
            Text("Recent Activity")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            // Transactions (up to 4)
            if entry.data.recentTransactions.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("No recent transactions")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                VStack(spacing: 6) {
                    ForEach(entry.data.recentTransactions.prefix(4)) { tx in
                        transactionRow(tx)
                    }
                }
            }

            Spacer(minLength: 0)

            // Footer
            HStack {
                Spacer()
                Text("Updated \(entry.data.lastUpdated, style: .relative) ago")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func transactionRow(_ tx: WidgetTransaction) -> some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: tx.isIncoming ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tx.isIncoming ? .green : .orange)
                .frame(width: 20, height: 20)
                .background(
                    (tx.isIncoming ? Color.green : Color.orange)
                        .opacity(0.15)
                )
                .cornerRadius(5)

            // Details
            VStack(alignment: .leading, spacing: 1) {
                Text(tx.isIncoming ? "Received" : "Sent")
                    .font(.caption2.weight(.medium))
                Text(tx.timestamp, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Amount
            VStack(alignment: .trailing, spacing: 1) {
                Text(tx.amountFormatted)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(tx.isIncoming ? .green : .primary)

                if !tx.isConfirmed {
                    Text("Pending")
                        .font(.system(size: 7))
                        .foregroundColor(.orange)
                }
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

struct TransactionsWidget_Previews: PreviewProvider {
    static var previews: some View {
        TransactionsWidgetView(entry: TransactionsEntry(date: Date(), data: WidgetDataManager.placeholder))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
        TransactionsWidgetView(entry: TransactionsEntry(date: Date(), data: WidgetDataManager.placeholder))
            .previewContext(WidgetPreviewContext(family: .systemLarge))
    }
}
