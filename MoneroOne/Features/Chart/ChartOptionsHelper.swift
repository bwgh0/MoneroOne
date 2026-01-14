import UIKit
import LightweightCharts

/// Helper to create chart options without SwiftUI type conflicts
enum ChartOptionsHelper {
    static func makeChartOptions(isDark: Bool) -> ChartOptions {
        // Layout options for dark/light mode
        let bgColor: ChartColor = isDark ? "#1c1c1e" : "#f2f2f7"
        let txtColor: ChartColor = isDark ? "#ffffff" : "#000000"

        let layoutOptions = LayoutOptions(
            background: .solid(color: bgColor),
            textColor: txtColor
        )

        // Time scale options - fix edges to show all data
        let timeScaleOptions = TimeScaleOptions(
            fixLeftEdge: true,
            fixRightEdge: true,
            borderVisible: false
        )

        // Chart options - disable scrolling/scaling so only crosshair works
        return ChartOptions(
            layout: layoutOptions,
            timeScale: timeScaleOptions,
            handleScroll: .enabled(false),
            handleScale: .enabled(false)
        )
    }

    static func makeSeriesOptions(isDark: Bool) -> AreaSeriesOptions {
        let markerBg: ChartColor = isDark ? "#1c1c1e" : "#ffffff"

        return AreaSeriesOptions(
            topColor: "rgba(255, 149, 0, 0.4)",
            bottomColor: "rgba(255, 149, 0, 0.0)",
            lineColor: "rgba(255, 149, 0, 1)",
            lineWidth: .two,
            crosshairMarkerVisible: true,
            crosshairMarkerRadius: 6,
            crosshairMarkerBorderColor: "rgba(255, 149, 0, 1)",
            crosshairMarkerBackgroundColor: markerBg
        )
    }
}
