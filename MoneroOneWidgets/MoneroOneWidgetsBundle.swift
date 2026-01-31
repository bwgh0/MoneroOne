import SwiftUI
import WidgetKit

@main
struct MoneroOneWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
        TransactionsWidget()
        PriceWidget()
        SyncLiveActivity()
    }
}
