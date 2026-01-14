import UIKit
import SwiftUI
import LightweightCharts

/// SwiftUI wrapper for TradingView's LightweightCharts
struct LightweightChartView: UIViewRepresentable {
    typealias UIViewType = LightweightCharts

    let data: [PriceDataPoint]
    @Binding var selectedPrice: Double?
    @Binding var selectedDate: Date?
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> LightweightCharts {
        let isDark = colorScheme == .dark

        // Use helper to create options (avoids SwiftUI type conflicts)
        let chartOptions = ChartOptionsHelper.makeChartOptions(isDark: isDark)
        let chart = LightweightCharts(options: chartOptions)
        chart.delegate = context.coordinator

        // Add area series
        let seriesOptions = ChartOptionsHelper.makeSeriesOptions(isDark: isDark)
        let series = chart.addAreaSeries(options: seriesOptions)
        context.coordinator.series = series

        // Subscribe to crosshair moves
        chart.subscribeCrosshairMove()

        return chart
    }

    func updateUIView(_ uiView: LightweightCharts, context: Context) {
        guard !data.isEmpty else { return }

        // Convert data to LightweightCharts format
        let chartData = data.map { point -> AreaData in
            let timestamp = Int(point.timestamp.timeIntervalSince1970)
            return AreaData(time: .utc(timestamp: Double(timestamp)), value: point.price)
        }

        context.coordinator.series?.setData(data: chartData)

        // Fit content to show all data
        uiView.timeScale().fitContent()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, ChartDelegate {
        var parent: LightweightChartView
        var series: AreaSeries?

        init(_ parent: LightweightChartView) {
            self.parent = parent
        }

        func didClick(onChart chart: ChartApi, parameters: MouseEventParams) {}

        func didCrosshairMove(onChart chart: ChartApi, parameters: MouseEventParams) {
            if case let .utc(timestamp) = parameters.time,
               let series = series,
               case let .lineData(priceData) = parameters.price(forSeries: series),
               let price = priceData.value {
                DispatchQueue.main.async {
                    self.parent.selectedPrice = price
                    self.parent.selectedDate = Date(timeIntervalSince1970: timestamp)
                }
            } else {
                DispatchQueue.main.async {
                    self.parent.selectedPrice = nil
                    self.parent.selectedDate = nil
                }
            }
        }

        func didVisibleTimeRangeChange(onChart chart: ChartApi, parameters: TimeRange?) {}
    }
}
