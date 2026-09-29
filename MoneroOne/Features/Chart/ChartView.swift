import SwiftUI

/// Market price and alerts. Personal balance history belongs to the wallet.
struct ChartView: View {
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var priceAlertService: PriceAlertService
    @Binding var path: [Destination]
    @State private var selectedTimeRange: ChartTimeRange = .week

    enum Destination: Hashable {
        case priceAlerts
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                PriceChartView(selectedTimeRange: $selectedTimeRange)
                    .padding()
            }
            .navigationTitle("Price")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { _ in
                PriceAlertsView(priceAlertService: priceAlertService, priceService: priceService)
            }
            .refreshable {
                await priceService.fetchPrice()
                await priceService.fetchChartData(range: selectedTimeRange.apiRange, force: true)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Destination.priceAlerts) {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("Price alerts")
                    .accessibilityHint("View and manage price alerts")
                }
            }
            .task { priceService.selectChartRange(selectedTimeRange.apiRange) }
            .onChange(of: selectedTimeRange) { _, range in
                priceService.selectChartRange(range.apiRange)
            }
        }
    }
}

enum ChartTimeRange: String, CaseIterable {
    case day = "24H"
    case week = "1W"
    case month = "1M"
    case year = "1Y"
    case all = "All"

    var apiRange: String {
        switch self {
        case .day: return "1D"
        case .week: return "7D"
        case .month: return "1M"
        case .year: return "1Y"
        case .all: return "All"
        }
    }

    var title: String { ChartRangeTitle.title(for: rawValue) }
}

/// The value and its supporting row occupy the same slots in both modes,
/// including while loading or scrubbing. Slots scale with Dynamic Type.
struct ChartValueHeader<Value: View, Details: View>: View {
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 42
    @ScaledMetric(relativeTo: .subheadline) private var detailsHeight: CGFloat = 34
    let value: Value
    let details: Details

    init(@ViewBuilder value: () -> Value, @ViewBuilder details: () -> Details) {
        self.value = value()
        self.details = details()
    }

    var body: some View {
        VStack(spacing: 8) {
            value
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: valueSize * 1.25)

            details
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: detailsHeight)
        }
        .padding(.vertical, 8)
    }
}

struct ChartChangeBadge: View {
    let change: Double?
    let timeAxis: ChartTimeAxis
    let isLoading: Bool

    private var color: Color {
        guard let change else { return .clear }
        return change >= 0 ? .green : .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: (change ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text(change.map { String(format: "%+.2f%%", $0) } ?? "0.00%")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if change == nil, isLoading {
                ProgressView().scaleEffect(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Change, \(timeAxis.spokenSpan)")
        .accessibilityValue(change.map(ChartSpeech.spokenChange) ?? "")
        .accessibilityHidden(change == nil)
        .fixedSize()
    }
}

struct ChartStatistics: View {
    let title: LocalizedStringResource
    let range: (min: Double, max: Double)?
    let selectedTimeRange: ChartTimeRange
    let lastUpdated: Date?
    let formatValue: (Double) -> String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCard(
                    title: String(localized: "\(selectedTimeRange.title) High", comment: "Highest price in the chart range, e.g. 1W High"),
                    value: range.map { formatValue($0.max) } ?? "—",
                    color: .green
                )
                StatCard(
                    title: String(localized: "\(selectedTimeRange.title) Low", comment: "Lowest price in the chart range, e.g. 1W Low"),
                    value: range.map { formatValue($0.min) } ?? "—",
                    color: .red
                )
            }

            if let lastUpdated {
                Text("Last updated \(lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    @Previewable @State var path: [ChartView.Destination] = []
    ChartView(path: $path)
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
