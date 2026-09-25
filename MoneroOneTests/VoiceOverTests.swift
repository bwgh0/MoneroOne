import XCTest
import SwiftUI
import Accessibility
@testable import MoneroOne

/// What VoiceOver gets from the wallet rows, read from the accessibility
/// tree SwiftUI builds for it. Moving one modifier changes this tree
/// without changing the screen, and XCUITest cannot see rotor actions, so
/// the tree is checked here.
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

    /// The More Content rotor. SwiftUI's elements answer it without
    /// declaring the protocol, so ask for the property by name.
    private func moreContent(of element: NSObject) -> [String] {
        guard element.responds(to: Selector(("accessibilityCustomContent"))),
              let content = element.value(forKey: "accessibilityCustomContent") as? [AXCustomContent] else { return [] }
        return content.map { "\($0.label): \($0.value)" }
    }
}
