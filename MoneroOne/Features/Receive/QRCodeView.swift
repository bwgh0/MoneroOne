import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let content: String
    var showLogo: Bool = true

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)

            ZStack {
                // One pixel per module, scaled up with interpolation off, so
                // the modules keep sharp edges at any size (focus mode too).
                if let qrImage = Self.qrImage(for: content) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size, height: size)
                }

                // Logo overlay in center: the flat mark on a white disc the
                // same size the old logo covered, so the modules stay clear
                // of the mark's edge and the code scans as before.
                if showLogo {
                    let plateSize = size * 0.22
                    Image("MoneroLogo")
                        .resizable()
                        .scaledToFit()
                        .padding(plateSize * 0.1)
                        .frame(width: plateSize, height: plateSize)
                        .background(Circle().fill(Color.white))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR code for Monero address")
        }
    }

    private static let context = CIContext()

    /// The code at one pixel per module, error correction H so the logo can
    /// cover the center. Nil when the text does not fit in a QR code.
    static func qrImage(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func isInFinderPattern(row: Int, col: Int, size: Int) -> Bool {
        // Top-left finder pattern
        if row < 7 && col < 7 { return true }
        // Top-right finder pattern
        if row < 7 && col >= size - 7 { return true }
        // Bottom-left finder pattern
        if row >= size - 7 && col < 7 { return true }
        return false
    }

    private func drawFinderPattern(context: inout GraphicsContext, x: CGFloat, y: CGFloat, moduleSize: CGFloat) {
        let patternSize = moduleSize * 7
        let cornerRadius = moduleSize * 1.2

        // Outer black rounded square (7x7)
        let outerRect = CGRect(x: x, y: y, width: patternSize, height: patternSize)
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius).path(in: outerRect),
            with: .color(.black)
        )

        // Middle white rounded square (5x5, inset by 1 module)
        let middleInset = moduleSize
        let middleRect = CGRect(x: x + middleInset, y: y + middleInset,
                                width: patternSize - (middleInset * 2),
                                height: patternSize - (middleInset * 2))
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius * 0.7).path(in: middleRect),
            with: .color(.white)
        )

        // Inner black rounded square (3x3, inset by 2 modules)
        let innerInset = moduleSize * 2
        let innerRect = CGRect(x: x + innerInset, y: y + innerInset,
                               width: patternSize - (innerInset * 2),
                               height: patternSize - (innerInset * 2))
        context.fill(
            RoundedRectangle(cornerRadius: cornerRadius * 0.5).path(in: innerRect),
            with: .color(.black)
        )
    }

    private func generateQRMatrix(from string: String) -> [[Bool]]? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        guard let pixelData = cgImage.dataProvider?.data,
              let dataPtr = CFDataGetBytePtr(pixelData) else {
            return nil
        }

        var matrix: [[Bool]] = []
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        for y in 0..<height {
            var row: [Bool] = []
            for x in 0..<width {
                let pixelIndex = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                let isBlack = dataPtr[pixelIndex] == 0
                row.append(isBlack)
            }
            matrix.append(row)
        }

        return matrix
    }
}

// MARK: - QR Code Image Generator (for sharing)

struct QRCodeRenderer {
    @MainActor
    static func renderToImage(content: String, size: CGFloat = 400) -> UIImage? {
        let renderer = ImageRenderer(content:
            QRCodeView(content: content)
                .frame(width: size, height: size)
        )
        renderer.scale = 3.0 // High resolution
        return renderer.uiImage
    }
}

// MARK: - Plate

/// A QR code on a white plate with a four-module quiet zone, in light and
/// dark mode: CoreImage draws one module of margin, the plate adds three.
/// The same plate sits on the Receive card, on Donate and in focus mode.
struct QRPlate: View {
    let content: String
    let side: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    /// Rounder as it grows: 12 pt on the card, up to 20 pt in focus mode.
    private var cornerRadius: CGFloat { min(20, max(12, side * 0.045)) }

    var body: some View {
        let modules = CGFloat(QRCodeView.qrImage(for: content)?.cgImage?.width ?? 49)
        let quietZone = side * 3 / (modules + 6)
        QRCodeView(content: content)
            .padding(quietZone)
            .frame(width: side, height: side)
            .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.black.opacity(colorScheme == .light ? 0.06 : 0))
            }
    }
}

// MARK: - Focus mode

/// What focus mode shows: the code, what it points at (VoiceOver reads it
/// with the code; the screen does not show it) and the requested amount.
struct QRFocusItem: Equatable {
    let content: String
    let title: String
    var amount: Decimal? = nil
}

/// A screen's focus mode as its views see it.
struct QRFocus {
    /// True while the code is large; the rest of the screen steps back.
    let isFocused: Bool
    /// True while the large copy of the code is on screen: the code on the
    /// screen hides and keeps its place, so only one code moves.
    let hidesSource: Bool
    /// False with Reduce Motion: the code cross-fades instead of growing.
    let grows: Bool
    /// Opens focus mode from a code at `frame` (global coordinates).
    let open: (QRFocusItem, CGRect) -> Void
    /// Where the code on the screen is now, so the copy shrinks back to it
    /// (an iPad may turn while focus mode is open).
    let trackSource: (CGRect) -> Void

    /// The grow and its reverse: one spring, the same path both ways.
    static let grow = Animation.spring(response: 0.5, dampingFraction: 0.86)
}

/// Where the code on the screen sits. A reference, so following it does not
/// redraw the screen.
final class QRFocusSource {
    var frame: CGRect = .zero
}

/// A screen whose QR code grows in place into focus mode, as Cake Wallet's
/// does: the code grows from where it sits to the width of the screen, the
/// Monero One lockup slides in above it, the rest of the screen steps back
/// behind the page color, and the screen goes to full brightness. A tap
/// anywhere, a swipe down or VoiceOver's escape shrinks it back along the
/// same path. The screen's views read `QRFocus` to step back;
/// `FocusableQRPlate` is the code they tap.
///
/// Focus mode is a clear full screen presentation that appears without an
/// animation of its own: its code starts on top of the one on the screen
/// and does all the moving. It covers the navigation bar, the tab bar and a
/// sheet's edges without changing the layout under them (hiding a bar moves
/// the whole screen mid-grow), and nothing behind it takes a touch.
struct QRFocusContainer<Content: View>: View {
    @ViewBuilder let content: (QRFocus) -> Content

    private struct Presentation: Identifiable {
        let id = UUID()
        let item: QRFocusItem
    }

    @State private var presented: Presentation?
    @State private var isFocused = false
    @State private var hidesSource = false
    @State private var source = QRFocusSource()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(QRFocus(
            isFocused: isFocused,
            hidesSource: hidesSource,
            grows: !reduceMotion,
            open: { open($0, from: $1) },
            trackSource: { [source] in source.frame = $0 }
        ))
        .fullScreenCover(item: $presented) { presentation in
            QRFocusView(
                item: presentation.item,
                source: source,
                grows: !reduceMotion,
                onShown: shown,
                onCloseStart: closeStarted,
                onClosed: closed
            )
            .presentationBackground(.clear)
        }
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : QRFocus.grow
    }

    private func open(_ item: QRFocusItem, from frame: CGRect) {
        guard presented == nil else { return }
        HapticFeedback.shared.softTick()
        // End editing (the Receive amount field), so the keyboard does not
        // stay up under the code.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        source.frame = frame
        withoutAnimation { presented = Presentation(item: item) }
    }

    /// The large copy is on screen over the code: hide the code, and step
    /// the screen back.
    private func shown() {
        withoutAnimation { hidesSource = !reduceMotion }
        withAnimation(animation) { isFocused = true }
    }

    private func closeStarted() {
        withAnimation(animation) { isFocused = false }
    }

    /// The copy is back on top of the code: show the code, then drop the
    /// presentation.
    private func closed() {
        withoutAnimation {
            hidesSource = false
            presented = nil
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

extension View {
    /// Steps out of the way while focus mode is open: fades, and moves
    /// toward `edge` unless Reduce Motion is on.
    func qrFocusRecede(_ focus: QRFocus, toward edge: VerticalEdge) -> some View {
        opacity(focus.isFocused ? 0 : 1)
            .offset(y: focus.isFocused && focus.grows ? (edge == .top ? -24 : 32) : 0)
    }
}

/// The code where it sits on a screen, and the tap that opens focus mode.
/// One VoiceOver element: a button that opens focus mode; callers add their
/// hint and actions after it. While focus mode is open the code hides and
/// keeps its place; its large copy is in `QRFocusView`.
struct FocusableQRPlate: View {
    let item: QRFocusItem
    let side: CGFloat
    let focus: QRFocus
    var label = String(localized: "QR code for Monero address")

    @State private var frame: CGRect = .zero

    var body: some View {
        QRPlate(content: item.content, side: side)
            .opacity(focus.hidesSource ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                frame = newFrame
                if focus.hidesSource { focus.trackSource(newFrame) }
            }
            .contentShape(Rectangle())
            .onTapGesture { focus.open(item, frame) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits([.isButton, .isImage])
            .accessibilityAction(.default) { focus.open(item, frame) }
    }
}

/// Focus mode itself: the Monero One lockup, the code as large as the
/// screen allows (16 pt margins, 448 pt at most) and the requested amount,
/// over the page color. The code starts on top of the one on the screen
/// and grows from there. Like Cake's, it shows no address: the code is the
/// address.
struct QRFocusView: View {
    let item: QRFocusItem
    let source: QRFocusSource
    let grows: Bool
    let onShown: () -> Void
    let onCloseStart: () -> Void
    let onClosed: () -> Void

    @State private var expanded = false
    @State private var closing = false
    /// VoiceOver starts on the code, so the escape gesture works at once.
    @AccessibilityFocusState private var codeFocused: Bool

    fileprivate static let lockupHeight: CGFloat = 28
    fileprivate static let amountHeight: CGFloat = 44
    fileprivate static let spacing: CGFloat = 24

    private var animation: Animation {
        grows ? QRFocus.grow : .easeInOut(duration: 0.25)
    }

    /// How long the shrink takes to land on the code on the screen: the
    /// grow spring is within 1% of its end by then. Timed, not a completion
    /// handler, which fired before the shrink ended here.
    private var settleTime: TimeInterval { grows ? 0.5 : 0.3 }

    var body: some View {
        // The layout keeps to the safe area (the Duo's sensor column, the
        // status bar, the home indicator); only the background fills the
        // screen, and it takes the taps there too.
        ZStack {
            Color(.systemBackground)
                .opacity(expanded ? 1 : 0)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            GeometryReader { geo in
                let layout = FocusLayout(size: geo.size, hasAmount: item.amount != nil)
                ZStack {
                    lockup
                        .position(x: geo.size.width / 2, y: layout.lockupCenterY)
                    plate(layout: layout, size: geo.size, origin: geo.frame(in: .global).origin)
                    amountPill
                        .position(x: geo.size.width / 2, y: layout.amountCenterY)
                }
            }
        }
        .contentShape(Rectangle())
        // One gesture for a tap anywhere and a swipe down.
        .gesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 10 || value.translation.height > 60 {
                    close()
                }
            }
        )
        .accessibilityAction(.escape, close)
        .background(FullBrightness())
        .onAppear {
            // The copy sits on top of the code while the code hides; the
            // grow starts a beat later, so the two never show at once.
            onShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                withAnimation(animation) { expanded = true }
            }
        }
        .task {
            // After the grow settles: VoiceOver would otherwise stay where
            // the presentation put it.
            try? await Task.sleep(for: .milliseconds(600))
            codeFocused = true
        }
    }

    private func close() {
        guard expanded, !closing else { return }
        closing = true
        onCloseStart()
        withAnimation(animation) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTime) {
            onClosed()
        }
    }

    /// Large and centered when open; on top of the code on the screen
    /// before it grows and after it shrinks back. With Reduce Motion it
    /// stays large and fades. `origin` is where the safe area starts, in
    /// the global coordinates the code on the screen reported.
    private func plate(layout: FocusLayout, size: CGSize, origin: CGPoint) -> some View {
        let large = expanded || !grows
        let from = source.frame
        let side = large ? layout.side : from.width
        let center = large
            ? CGPoint(x: size.width / 2, y: layout.plateCenterY)
            : CGPoint(x: from.midX - origin.x, y: from.midY - origin.y)
        let amount = item.amount.map { "\(XMRFormatter.format($0)) XMR" }
        return QRPlate(content: item.content, side: side)
            .opacity(grows || expanded ? 1 : 0)
            .position(center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR code for Monero address")
            .accessibilityValue([item.title, amount].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isImage)
            .accessibilityHint(String(localized: "Double tap to make it small again.", comment: "VoiceOver hint: the QR code in focus mode"))
            .accessibilityAction(.default, close)
            .accessibilityIdentifier("qrFocus.code")
            .accessibilityFocused($codeFocused)
    }

    /// Slides down from the top a beat after the code starts to grow.
    private var lockup: some View {
        HStack(spacing: 8) {
            Image("MoneroLogo")
                .resizable()
                .scaledToFit()
                .frame(width: Self.lockupHeight, height: Self.lockupHeight)
            Text(verbatim: "Monero One")
                .font(.headline.bold())
        }
        .frame(height: Self.lockupHeight)
        .opacity(expanded ? 1 : 0)
        .offset(y: expanded || !grows ? 0 : -20)
        .animation(
            grows
                ? .easeOut(duration: expanded ? 0.4 : 0.2).delay(expanded ? 0.1 : 0)
                : .easeInOut(duration: 0.25),
            value: expanded
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var amountPill: some View {
        if let amount = item.amount {
            Text("\(XMRFormatter.format(amount)) XMR")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .frame(height: Self.amountHeight)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded || !grows ? 1 : 0.9)
                .animation(
                    grows
                        ? .easeOut(duration: expanded ? 0.3 : 0.15).delay(expanded ? 0.15 : 0)
                        : .easeInOut(duration: 0.25),
                    value: expanded
                )
                .accessibilityHidden(true)
        }
    }
}

/// Where focus mode puts the lockup, the code and the amount in the safe
/// area: the largest code that fits with 16 pt margins and 32 pt above and
/// below, 448 pt at most, the group centered.
private struct FocusLayout {
    let side: CGFloat
    let lockupCenterY: CGFloat
    let plateCenterY: CGFloat
    let amountCenterY: CGFloat

    init(size: CGSize, hasAmount: Bool) {
        let lockup = QRFocusView.lockupHeight, amount = QRFocusView.amountHeight, gap = QRFocusView.spacing
        var reserved = lockup + gap + 2 * 32
        if hasAmount { reserved += gap + amount }
        side = max(160, min(size.width - 32, 448, size.height - reserved))
        var total = lockup + gap + side
        if hasAmount { total += gap + amount }
        let top = (size.height - total) / 2
        lockupCenterY = top + lockup / 2
        plateCenterY = top + lockup + gap + side / 2
        amountCenterY = plateCenterY + side / 2 + gap + amount / 2
    }
}

/// Full screen brightness while this view is in a window, the old level back
/// when it leaves or its scene goes inactive. Reads the window's own screen,
/// not `UIScreen.main`.
struct FullBrightness: UIViewRepresentable {
    func makeUIView(context: Context) -> BrightnessView { BrightnessView() }
    func updateUIView(_ uiView: BrightnessView, context: Context) {}

    final class BrightnessView: UIView {
        private weak var screen: UIScreen?
        private var savedBrightness: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopObserving()
            guard let scene = window?.windowScene else {
                restore()
                return
            }
            boost(scene.screen)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                    self?.restore()
                },
                center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self, weak scene] _ in
                    guard let scene else { return }
                    self?.boost(scene.screen)
                },
            ]
        }

        private func boost(_ screen: UIScreen) {
            if savedBrightness == nil {
                savedBrightness = screen.brightness
            }
            self.screen = screen
            screen.brightness = 1
        }

        private func restore() {
            guard let saved = savedBrightness else { return }
            screen?.brightness = saved
            savedBrightness = nil
        }

        private func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
        }
    }
}

#Preview {
    QRCodeView(content: "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H")
        .frame(width: 200, height: 200)
        .padding()
        .background(Color.white)
}

#Preview("Focus mode") {
    QRFocusContainer { focus in
        FocusableQRPlate(
            item: QRFocusItem(
                content: "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H?tx_amount=0.5",
                title: "Subaddress #1",
                amount: 0.5
            ),
            side: 240,
            focus: focus
        )
    }
}
