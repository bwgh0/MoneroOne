import SwiftUI

/// Market price and alerts. Personal balance history belongs to the wallet.
struct ChartView: View {
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var priceAlertService: PriceAlertService
    @Binding var path: [Destination]
    @State private var selectedTimeRange: ChartTimeRange = .week
    /// Wider than a phone (the open iPhone Duo, iPad): High and Low beside
    /// the price, the chart full width. Width, not size class: the Duo
    /// cover is 466pt wide.
    @State private var isWide = false
    @State private var viewportHeight: CGFloat = 0

    private static let phoneWidth: CGFloat = 466
    private static let margin: CGFloat = 16

    enum Destination: Hashable {
        case priceAlerts
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // Wide: the chart fills the visible height, so nothing
                // scrolls; taller content (large text) grows and scrolls.
                PriceChartView(
                    selectedTimeRange: $selectedTimeRange,
                    isWide: isWide,
                    fillHeight: isWide ? viewportHeight - 2 * Self.margin : 0
                )
                .padding(Self.margin)
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                // A layout pass can report 466.0000000000001 for the cover.
                isWide = size.width > Self.phoneWidth + 1
                viewportHeight = size.height
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
    /// Wide windows: the details beside the value, from the leading edge.
    let isInline: Bool
    let value: Value
    let details: Details

    init(isInline: Bool = false, @ViewBuilder value: () -> Value, @ViewBuilder details: () -> Details) {
        self.isInline = isInline
        self.value = value()
        self.details = details()
    }

    var body: some View {
        if isInline {
            HStack(spacing: 16) {
                styledValue
                    .frame(height: valueSize * 1.25)
                // The value shrinks first (large text); the range label
                // keeps its width.
                styledDetails
                    .frame(height: detailsHeight)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                styledValue
                    .frame(maxWidth: .infinity)
                    .frame(height: valueSize * 1.25)
                styledDetails
                    .frame(maxWidth: .infinity)
                    .frame(height: detailsHeight)
            }
            .padding(.vertical, 8)
        }
    }

    private var styledValue: some View {
        value
            .font(.system(size: valueSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var styledDetails: some View {
        details
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
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
    /// Wide windows: High and Low as two plain pairs beside the price, no
    /// title and no cards.
    var isInline = false
    let formatValue: (Double) -> String

    private var highTitle: String {
        String(localized: "\(selectedTimeRange.title) High", comment: "Highest price in the chart range, e.g. 1W High")
    }

    private var lowTitle: String {
        String(localized: "\(selectedTimeRange.title) Low", comment: "Lowest price in the chart range, e.g. 1W Low")
    }

    private var highValue: String { range.map { formatValue($0.max) } ?? "—" }
    private var lowValue: String { range.map { formatValue($0.min) } ?? "—" }

    var body: some View {
        if isInline {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(alignment: .top, spacing: 24) {
                    InlineStat(title: highTitle, value: highValue, color: .green)
                    InlineStat(title: lowTitle, value: lowValue, color: .red)
                }
                .fixedSize(horizontal: true, vertical: false)
                lastUpdatedLine
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        } else {
            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: highTitle, value: highValue, color: .green)
                    StatCard(title: lowTitle, value: lowValue, color: .red)
                }

                lastUpdatedLine
            }
        }
    }

    @ViewBuilder
    private var lastUpdatedLine: some View {
        if let lastUpdated {
            Text("Last updated \(lastUpdated, style: .relative) ago")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A StatCard's title and value without the card, trailing (wide header).
private struct InlineStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

#Preview {
    @Previewable @State var path: [ChartView.Destination] = []
    ChartView(path: $path)
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
        .environmentObject(PriceAlertService())
}
