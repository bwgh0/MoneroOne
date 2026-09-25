import XCTest
import SwiftUI
import Accessibility
@testable import MoneroOne

/// What VoiceOver gets from the wallet rows and the charts, read from the
/// accessibility tree SwiftUI builds for it. Moving one modifier changes
/// this tree without changing the screen, and XCUITest cannot see rotor
/// actions, so the tree is checked here.
@MainActor
final class VoiceOverTests: XCTestCase {
    private var window: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // SwiftUI builds the tree only while accessibility is on. This is
        // the switch AccessibilitySnapshot uses in its tests.
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("No switch to turn accessibility on")
        }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(true)
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: - Wallet rows

    /// One stop per wallet: name and balance, no separate pencil, no
    /// address read aloud, and Rename / Delete / Move up / Move down on
    /// the rotor in that order.
    func testWalletRowIsOneElementWithItsActionsOnTheRotor() {
        let savings = wallet("Savings", emoji: "🏦", source: .viewOnly, address: "44AFFq5kSiGBoZ4NMDwY")
        var calls: [String] = []
        let rows = VStack {
            row(wallet("Wallet 1", source: .seed(.polyseed), address: "49pYEPhMVg43jhDUMquM"), active: false)
            WalletRow(
                wallet: savings, isActive: false, balance: 1.25, address: savings.cachedPrimaryAddress,
                onTap: {}, onRename: { calls.append("rename") }, onDelete: { calls.append("delete") },
                onMoveUp: { calls.append("up") }, onMoveDown: { calls.append("down") }, isLifted: false
            )
            row(wallet("Wallet 2", source: .seed(.polyseed), address: "4B2CxkXw4Wy7cpwrQTdJ"), active: false)
        }

        let elements = accessibilityElements(in: host(rows, height: 420))

        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }, [
            "Wallet 1, \(MoneroOne.XMRFormatter.format(0)) XMR",
            "Savings, \(MoneroOne.XMRFormatter.format(1.25)) XMR, view-only",
            "Wallet 2, \(MoneroOne.XMRFormatter.format(0)) XMR",
        ], "one element per wallet")
        let middle = elements[1]
        XCTAssertEqual(middle.accessibilityCustomActions?.map(\.name), ["Rename", "Delete", "Move up", "Move down"])
        XCTAssertEqual(moreContent(of: middle), ["Address: 44AFFq5kSiGBoZ4NMDwY", "Icon: 🏦"])

        for action in middle.accessibilityCustomActions ?? [] {
            _ = action.actionHandler?(action)
        }
        XCTAssertEqual(calls, ["rename", "delete", "up", "down"])
    }

    /// The active wallet is Selected and has no Delete: it is deleted from
    /// Settings, as on screen.
    func testActiveWalletRowIsSelectedWithoutDelete() {
        let first = wallet("Wallet 1", source: .seed(.polyseed), address: "49pYEPhMVg43jhDUMquM")
        let elements = accessibilityElements(in: host(row(first, active: true, first: true), height: 140))

        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(elements[0].accessibilityTraits.contains(.selected))
        XCTAssertEqual(elements[0].accessibilityCustomActions?.map(\.name), ["Rename", "Move down"])
    }

    // MARK: - Charts

    /// The chart is one adjustable element: its value sums the line up, a
    /// swipe up or down steps through the markers and stops at the ends,
    /// each step pins the sample like a tap, and the rotor has an Audio
    /// Graph of every sample.
    func testChartStepsThroughItsMarkers() {
        let points = samples(price: { 1000 + Double($0) * 5 })
        let markers = [5, 20, 40].map { i in
            ChartMarker(
                timestamp: points[i].timestamp, value: points[i].price, style: i == 20 ? .sent : .received,
                accessibilityLabel: i == 20 ? "Sent 0.5000 XMR" : "Received 1.0000 XMR",
                accessibilityValue: "sample \(i)"
            )
        }
        let speech = ChartSpeech(
            title: "Portfolio", span: "past week", currencyCode: "usd",
            note: "3 transactions", markerHint: "Moves between transactions"
        )
        var selected: [Date?] = []
        let chart = SampledLineChart(
            points: points, domain: 950...1300, timestamp: \.timestamp, value: \.price,
            axes: .init(time: .week, currencyCode: "USD"), markers: markers, speech: speech,
            onSelect: { selected.append($0?.timestamp) }
        )
        let root = host(chart.frame(height: 240), height: 260)

        let elements = accessibilityElements(in: root)
        XCTAssertEqual(elements.count, 1, "one stop, not one per day")
        guard let element = elements.first else { return }
        XCTAssertEqual(element.accessibilityLabel, "Portfolio chart, past week")
        XCTAssertEqual(element.accessibilityValue, speech.summary(first: 1000, last: 1245))
        XCTAssertTrue(element.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(element.accessibilityHint, "Moves between transactions")

        let graph = (element as? AXChart)?.accessibilityChartDescriptor
        XCTAssertEqual(graph?.series.first?.dataPoints.count, points.count, "every sample")
        XCTAssertEqual(graph?.series.first?.dataPoints.compactMap(\.label).count, 3, "the markers' words")

        var heard: [String] = []
        for up in [true, true, true, true, false, false, false] {
            if up { element.accessibilityIncrement() } else { element.accessibilityDecrement() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            heard.append(accessibilityElements(in: root).first?.accessibilityValue ?? "")
        }
        XCTAssertEqual(heard, [
            "Received 1.0000 XMR, sample 5, 1 of 3",
            "Sent 0.5000 XMR, sample 20, 2 of 3",
            "Received 1.0000 XMR, sample 40, 3 of 3",
            "Received 1.0000 XMR, sample 40, 3 of 3",
            "Sent 0.5000 XMR, sample 20, 2 of 3",
            "Received 1.0000 XMR, sample 5, 1 of 3",
            "Received 1.0000 XMR, sample 5, 1 of 3",
        ])
        XCTAssertEqual(selected.last, points[5].timestamp, "the header shows the pinned sample")
    }

    /// Without markers there is nothing to step to.
    func testChartWithoutMarkersIsNotAdjustable() {
        let points = samples(price: { 500 + Double($0) })
        let chart = SampledLineChart(
            points: points, domain: 450...600, timestamp: \.timestamp, value: \.price,
            axes: nil, speech: ChartSpeech(title: "Monero price", span: "past week", currencyCode: "eur"),
            onSelect: { _ in }
        )

        let elements = accessibilityElements(in: host(chart.frame(height: 200), height: 220))

        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.accessibilityLabel, "Monero price chart, past week")
        XCTAssertFalse(elements.first?.accessibilityTraits.contains(.adjustable) ?? true)
    }

    // MARK: - Full screen QR

    /// The Receive QR is a button: VoiceOver's double tap opens the full
    /// screen page, and the escape gesture (two-finger Z) closes it.
    func testQRFullscreenOpensOnDoubleTapAndClosesOnEscape() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let address = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
        // The same modifier order as ReceiveView.
        let smallQR = QRCodeView(content: "monero:\(address)")
            .frame(width: 280, height: 280)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR code for receiving Monero")
            .opensQRFullscreen(content: "monero:\(address)", title: "Main Address", address: address, amount: nil)
        let controller = UIHostingController(rootView: smallQR)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let small = try XCTUnwrap(accessibilityElements(in: controller.view).first)
        XCTAssertEqual(small.accessibilityLabel, "QR code for receiving Monero")
        XCTAssertTrue(small.accessibilityTraits.contains(.button), "VoiceOver says it can be activated")
        XCTAssertTrue(small.accessibilityActivate())
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let presented = try XCTUnwrap(controller.presentedViewController, "double tap opens full screen")

        let page = accessibilityElements(in: presented.view)
        XCTAssertTrue(page.contains { $0.accessibilityLabel == "Close" }, "a Close button")
        let caption = try XCTUnwrap(page.first { $0.accessibilityLabel?.hasPrefix("Main Address") == true }, "the caption")
        XCTAssertTrue(performEscape(from: caption), "the page takes the escape gesture")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertNil(controller.presentedViewController, "escape closes full screen")
    }

    // MARK: - Helpers

    private func wallet(_ name: String, emoji: String = "💰", source: WalletSource, address: String) -> WalletInfo {
        WalletInfo(
            id: UUID(), name: name, emoji: emoji, source: source, createdAt: Date(), restoreHeight: 0,
            syncResetCount: 0, userCreatedSubaddressIndices: [], cachedPrimaryAddress: address, cachedBalance: 0
        )
    }

    private func row(_ wallet: WalletInfo, active: Bool, first: Bool = false) -> WalletRow {
        WalletRow(
            wallet: wallet, isActive: active, balance: 0, address: wallet.cachedPrimaryAddress,
            onTap: {}, onRename: {}, onDelete: active ? nil : {},
            onMoveUp: first ? nil : {}, onMoveDown: {}, isLifted: false
        )
    }

    /// 50 samples, 3.5 hours apart, across the past week.
    private func samples(price: (Int) -> Double) -> [PriceDataPoint] {
        let start = Date().addingTimeInterval(-7 * 24 * 3600)
        return (0..<50).map { PriceDataPoint(timestamp: start.addingTimeInterval(Double($0) * 3.5 * 3600), price: price($0)) }
    }

    private func host<V: View>(_ view: V, height: CGFloat) -> UIView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        self.window = window
        return controller.view
    }

    /// The elements VoiceOver visits, in order.
    private func accessibilityElements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ node: NSObject) {
            if node.isAccessibilityElement {
                found.append(node)
            } else if let children = node.accessibilityElements as? [NSObject], !children.isEmpty {
                children.forEach(walk)
            } else if case let count = node.accessibilityElementCount(), count != NSNotFound, count > 0 {
                (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }.forEach(walk)
            } else if let view = node as? UIView {
                view.subviews.forEach(walk)
            }
        }
        walk(root)
        return found
    }

    /// What VoiceOver's escape gesture does: offer it to the focused
    /// element, then to each container above it, until one takes it.
    private func performEscape(from element: NSObject) -> Bool {
        var node: NSObject? = element
        let container = Selector(("accessibilityContainer"))
        while let current = node {
            if current.accessibilityPerformEscape() { return true }
            let parent = current.responds(to: container)
                ? current.perform(container)?.takeUnretainedValue() as? NSObject
                : nil
            node = parent ?? (current as? UIView)?.superview
        }
        return false
    }

    /// The More Content rotor. SwiftUI's elements answer it without
    /// declaring the protocol, so ask for the property by name.
    private func moreContent(of element: NSObject) -> [String] {
        guard element.responds(to: Selector(("accessibilityCustomContent"))),
              let content = element.value(forKey: "accessibilityCustomContent") as? [AXCustomContent] else { return [] }
        return content.map { "\($0.label): \($0.value)" }
    }
}
