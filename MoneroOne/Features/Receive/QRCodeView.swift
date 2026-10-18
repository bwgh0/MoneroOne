import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let content: String
    var showLogo: Bool = true

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)

            let bitmap = Self.bitmap(for: content)

            ZStack {
                // Many pixels per module, scaled down smoothly: the modules
                // keep clean edges at any size and glide as focus mode
                // grows the code. One pixel per module scaled up with
                // interpolation off jumped a pixel at a time mid-grow.
                if let bitmap {
                    Image(uiImage: bitmap.image)
                        .interpolation(.medium)
                        .resizable()
                        .frame(width: size, height: size)
                }

                // The flat mark in the center. The rounded code leaves its
                // center clear, so the mark sits there on its own; the
                // square fallback puts it on a white disc over the modules.
                if showLogo {
                    let onDisc = bitmap?.logoOnDisc ?? true
                    let logoSize = size * (bitmap?.logoFraction ?? 0.22)
                    Image("MoneroLogo")
                        .resizable()
                        .scaledToFit()
                        .padding(onDisc ? logoSize * 0.1 : 0)
                        .frame(width: logoSize, height: logoSize)
                        .background(Circle().fill(onDisc ? Color.white : Color.clear))
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
    /// One bitmap per text. A new UIImage for the same code is new content
    /// to SwiftUI, and inside an animation it cross-fades the old bitmap
    /// into the new one: focus mode's grow and shrink showed two codes, the
    /// old one pinned at its old size.
    private static let cache = NSCache<NSString, QRBitmap>()

    /// The bitmap is at least this many pixels wide: the largest code focus
    /// mode shows (448 pt) at 3x, so a code is only ever scaled down.
    private static let bitmapWidth: CGFloat = 1344

    /// The code at a whole number of pixels per module: the rounded code,
    /// or the square code when the rounded one cannot be drawn. Nil when
    /// the text does not fit in a QR code.
    static func bitmap(for string: String) -> QRBitmap? {
        if let cached = cache.object(forKey: string as NSString) {
            return cached
        }
        guard let bitmap = roundedBitmap(for: string) ?? squareBitmap(for: string) else {
            return nil
        }
        cache.setObject(bitmap, forKey: string as NSString)
        return bitmap
    }

    /// Round dots and rounded finder patterns with the center cleared for
    /// the mark (`QRStyle.swift`), error correction Q. No margin: the plate
    /// adds the whole quiet zone.
    private static func roundedBitmap(for string: String) -> QRBitmap? {
        guard let matrix = QRMatrix.make(string) else { return nil }
        let style = QRStyle()
        let modules = matrix.size
        let pixelWidth = modules * Int((bitmapWidth / CGFloat(modules)).rounded(.up))
        let side = CGFloat(pixelWidth)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelWidth,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // y down, like the path. Even-odd: the finder rings have holes.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.addPath(QRStyledCode.path(matrix: matrix, style: style, side: side))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath(using: .evenOdd)
        guard let cgImage = context.makeImage() else { return nil }
        let logo = QRStyledCode.logoRect(matrix: matrix, style: style, side: side)
        return QRBitmap(
            image: UIImage(cgImage: cgImage),
            modules: modules,
            margin: 0,
            logoFraction: logo.width / side,
            logoOnDisc: false
        )
    }

    /// Square modules, error correction H so the mark's disc can cover the
    /// center, with CoreImage's one-module margin.
    private static func squareBitmap(for string: String) -> QRBitmap? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        // CoreImage draws one pixel per module.
        let modules = Int(output.extent.width.rounded())
        let scale = (bitmapWidth / CGFloat(modules)).rounded(.up)
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(
            scaled,
            from: scaled.extent,
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        ) else {
            return nil
        }
        return QRBitmap(
            image: UIImage(cgImage: cgImage),
            modules: modules,
            margin: 1,
            logoFraction: 0.22,
            logoOnDisc: true
        )
    }
}

/// A QR code bitmap and where the mark goes on it.
final class QRBitmap {
    let image: UIImage
    /// The bitmap's width in modules, margin included.
    let modules: Int
    /// The white modules the bitmap draws around the code.
    let margin: Int
    /// The mark's width as a fraction of the bitmap's width.
    let logoFraction: CGFloat
    /// True when the mark needs a white disc under it: the square code does
    /// not clear its center.
    let logoOnDisc: Bool

    init(image: UIImage, modules: Int, margin: Int, logoFraction: CGFloat, logoOnDisc: Bool) {
        self.image = image
        self.modules = modules
        self.margin = margin
        self.logoFraction = logoFraction
        self.logoOnDisc = logoOnDisc
    }
}

// MARK: - QR Code Image Generator (for sharing)

struct QRCodeRenderer {
    /// The code on white with the plate's four-module quiet zone, so the
    /// saved or shared image scans on its own.
    @MainActor
    static func renderToImage(content: String, size: CGFloat = 400) -> UIImage? {
        let renderer = ImageRenderer(content:
            QRCodeView(content: content)
                .padding(QRPlate.quietZone(for: content, side: size))
                .frame(width: size, height: size)
                .background(Color.white)
        )
        renderer.scale = 3.0 // High resolution
        return renderer.uiImage
    }
}

// MARK: - Plate

/// A QR code on a white plate with a four-module quiet zone, in light and
/// dark mode: the plate adds what the bitmap's own margin leaves out (all
/// four for the rounded code, three for the square one). The same plate sits on the Receive card, on Donate and in focus mode.
/// It casts its own shadow, so focus mode's copy starts and ends looking
/// exactly like the code it grows from.
struct QRPlate: View {
    let content: String
    let side: CGFloat
    var castsShadow = true

    @Environment(\.colorScheme) private var colorScheme

    /// Rounder as it grows: 12 pt on the card, up to 20 pt in focus mode.
    private var cornerRadius: CGFloat { min(20, max(12, side * 0.045)) }

    var body: some View {
        QRCodeView(content: content)
            .padding(Self.quietZone(for: content, side: side))
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(castsShadow ? 0.1 : 0), radius: 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.black.opacity(colorScheme == .light ? 0.06 : 0))
            }
    }

    /// The white to add on each side of the code in a square `side` wide,
    /// so the code has four modules of quiet zone.
    static func quietZone(for content: String, side: CGFloat) -> CGFloat {
        let bitmap = QRCodeView.bitmap(for: content)
        let modules = CGFloat(bitmap?.modules ?? 49)
        let added = CGFloat(4 - (bitmap?.margin ?? 0))
        return side * added / (modules + 2 * added)
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

/// A screen's focus mode: what its views read to step back, and what the
/// code they tap opens. Observable, so a change redraws only the views that
/// read it (the code, the parts that step back, the presentation), never
/// the whole screen: a screen that redraws as the grow starts drops the
/// grow's first frames.
@MainActor @Observable
final class QRFocus {
    /// True while the code is large; the rest of the screen steps back.
    private(set) var isFocused = false
    /// True while the large copy of the code is on screen: the code on the
    /// screen hides and keeps its place, so only one code moves.
    private(set) var hidesSource = false
    fileprivate var presented: QRFocusPresentation?
    /// Where the code on the screen sits, in global coordinates: the copy
    /// grows from it and shrinks back to it. Not observed, so following
    /// the code redraws nothing.
    @ObservationIgnored fileprivate var sourceFrame: CGRect = .zero

    /// The grow and its reverse: one curve, the same path both ways. It
    /// keeps within a percent of a spring (response 0.5, damping 0.86) but
    /// ends at `moveDuration` exactly. The spring's tail was a pixel from
    /// rest at 0.6 s: the grow snapped that pixel out in one frame when the
    /// spring stopped, and the shrink when the code on the screen came back.
    static let move = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: moveDuration)
    static let moveDuration: TimeInterval = 0.42
    /// With Reduce Motion: a cross-fade both ways.
    static let fade = Animation.easeInOut(duration: fadeDuration)
    static let fadeDuration: TimeInterval = 0.25

    /// Opens focus mode from a code at `frame` (global coordinates).
    func open(_ item: QRFocusItem, from frame: CGRect) {
        guard presented == nil else { return }
        HapticFeedback.shared.softTick()
        // End editing (the Receive amount field), so the keyboard does not
        // stay up under the code.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        sourceFrame = frame
        withoutAnimation { presented = QRFocusPresentation(item: item) }
    }

    /// Where the code on the screen is now, so the copy shrinks back to it
    /// (an iPad may turn while focus mode is open).
    func trackSource(_ frame: CGRect) {
        sourceFrame = frame
    }

    /// The large copy is on screen over the code: hide the code, and step
    /// the screen back.
    fileprivate func shown(grows: Bool) {
        withoutAnimation { hidesSource = grows }
        withAnimation(Self.animation(grows: grows)) { isFocused = true }
    }

    fileprivate func closeStarted(grows: Bool) {
        withAnimation(Self.animation(grows: grows)) { isFocused = false }
    }

    /// The copy is back on top of the code: show the code, then drop the
    /// presentation.
    fileprivate func closed() {
        withoutAnimation {
            hidesSource = false
            presented = nil
        }
    }

    /// The grow, or a cross-fade with Reduce Motion.
    fileprivate static func animation(grows: Bool) -> Animation {
        grows ? move : fade
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

fileprivate struct QRFocusPresentation: Identifiable {
    let id = UUID()
    let item: QRFocusItem
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

    /// Held, not read here: opening and closing focus mode never runs
    /// `content` again.
    @State private var focus = QRFocus()

    var body: some View {
        content(focus)
            .modifier(QRFocusPresenter(focus: focus))
    }
}

/// The presentation, in its own modifier so presenting and dismissing
/// redraw only this.
private struct QRFocusPresenter: ViewModifier {
    @Bindable var focus: QRFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $focus.presented) { presentation in
            QRFocusView(item: presentation.item, focus: focus, grows: !reduceMotion)
                .presentationBackground(.clear)
        }
    }
}

extension View {
    /// Steps out of the way while focus mode is open: fades, and moves
    /// toward `edge` unless Reduce Motion is on.
    func qrFocusRecede(_ focus: QRFocus, toward edge: VerticalEdge) -> some View {
        modifier(QRFocusRecede(focus: focus, edge: edge))
    }
}

/// Reads `isFocused` in its own body, so focus mode redraws only this, not
/// the view it steps back.
private struct QRFocusRecede: ViewModifier {
    let focus: QRFocus
    let edge: VerticalEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(focus.isFocused ? 0 : 1)
            .offset(y: focus.isFocused && !reduceMotion ? (edge == .top ? -24 : 32) : 0)
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
            .onTapGesture { focus.open(item, from: frame) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits([.isButton, .isImage])
            .accessibilityAction(.default) { focus.open(item, from: frame) }
    }
}

/// Focus mode itself: the Monero One lockup, the code as large as the
/// screen allows (16 pt margins, 448 pt at most) and the requested amount,
/// over the page color. The code starts on top of the one on the screen
/// and grows from there. Like Cake's, it shows no address: the code is the
/// address.
struct QRFocusView: View {
    let item: QRFocusItem
    let focus: QRFocus
    let grows: Bool

    @State private var expanded = false
    @State private var closing = false
    /// VoiceOver starts on the code, so the escape gesture works at once.
    @AccessibilityFocusState private var codeFocused: Bool

    fileprivate static let lockupHeight: CGFloat = 28
    fileprivate static let amountHeight: CGFloat = 44
    fileprivate static let spacing: CGFloat = 24

    private var animation: Animation { QRFocus.animation(grows: grows) }

    /// How long the shrink takes to land on the code on the screen, and two
    /// frames to spare. A close during the grow needs the same wait: the
    /// grow started first, so it ends first. Timed, not a completion
    /// handler, which fired before the shrink ended here.
    private var settleTime: TimeInterval {
        (grows ? QRFocus.moveDuration : QRFocus.fadeDuration) + 0.03
    }

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
        .background(FullBrightness(isOn: expanded))
        .onAppear {
            // The copy starts on top of the code, the code hides in the
            // same frame, and the grow starts at once: a wait here reads
            // as lag.
            focus.shown(grows: grows)
            withAnimation(animation) { expanded = true }
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
        focus.closeStarted(grows: grows)
        withAnimation(animation) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTime) {
            focus.closed()
        }
    }

    /// Large and centered when open; on top of the code on the screen
    /// before it grows and after it shrinks back. With Reduce Motion it
    /// stays large and fades. `origin` is where the safe area starts, in
    /// the global coordinates the code on the screen reported.
    private func plate(layout: FocusLayout, size: CGSize, origin: CGPoint) -> some View {
        let large = expanded || !grows
        let from = focus.sourceFrame
        let side = large ? layout.side : from.width
        let center = large
            ? CGPoint(x: size.width / 2, y: layout.plateCenterY)
            : CGPoint(x: from.midX - origin.x, y: from.midY - origin.y)
        let amount = item.amount.map { "\(XMRFormatter.format($0)) XMR" }
        // The copy's shadow goes in the same update that shows the code on
        // the screen again. The presentation leaves frames later, and two
        // shadows in one place blinked darker until it did.
        return QRPlate(content: item.content, side: side, castsShadow: focus.hidesSource || !grows)
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

    /// Slides down from the top as the code grows. The lockup and the
    /// amount move on the grow's own curve: a curve and a delay of their
    /// own started them a beat late, a second motion inside the first.
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

/// A brightness level to set: the screen, or a stand-in in tests.
@MainActor
protocol BrightnessScreen: AnyObject {
    var brightness: CGFloat { get set }
}

extension UIScreen: BrightnessScreen {}

/// Full screen brightness while `isOn` and this view is in a window. The
/// level eases up as focus mode opens and back down as it closes: a jump in
/// one frame read as a flash. The old level comes back at once when the view
/// leaves its window or its scene goes inactive. Reads the window's own
/// screen, not `UIScreen.main`.
struct FullBrightness: UIViewRepresentable {
    var isOn: Bool

    func makeUIView(context: Context) -> BrightnessView { BrightnessView() }
    func updateUIView(_ uiView: BrightnessView, context: Context) {
        uiView.setOn(isOn)
    }

    final class BrightnessView: UIView {
        /// Up over about the length of the grow. Down ends before the
        /// shrink does, so the level is back as the code lands.
        private static let upDuration: CFTimeInterval = 0.45
        private static let downDuration: CFTimeInterval = 0.3

        private struct Ramp {
            let from: CGFloat
            let to: CGFloat
            let start: CFTimeInterval
            let duration: CFTimeInterval
        }

        /// Tests set a stand-in: the simulator's screen keeps its level.
        var testScreen: BrightnessScreen?
        private weak var screen: BrightnessScreen?
        private var isOn = false
        /// The level before focus mode, saved once per open.
        private var savedBrightness: CGFloat?
        private var ramp: Ramp?
        private var displayLink: CADisplayLink?
        private var observers: [NSObjectProtocol] = []

        func setOn(_ on: Bool) {
            guard on != isOn else { return }
            isOn = on
            if on { boost() } else { dim() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopObserving()
            guard let scene = window?.windowScene else {
                restore()
                return
            }
            screen = testScreen ?? scene.screen
            if isOn { boost() }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                    self?.restore()
                },
                center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                    // The user may have set a new level meanwhile: boost
                    // saves it again.
                    guard let self, self.isOn else { return }
                    self.boost()
                },
            ]
        }

        private func boost() {
            guard let screen else { return }
            if savedBrightness == nil {
                savedBrightness = screen.brightness
            }
            animate(to: 1, over: Self.upDuration)
        }

        private func dim() {
            guard let saved = savedBrightness else { return }
            animate(to: saved, over: Self.downDuration)
        }

        /// The saved level at once: the app or this view is leaving the
        /// screen.
        private func restore() {
            stopRamp()
            guard let saved = savedBrightness else { return }
            screen?.brightness = saved
            savedBrightness = nil
        }

        private func animate(to target: CGFloat, over duration: CFTimeInterval) {
            stopRamp()
            guard let screen else { return }
            let from = screen.brightness
            guard abs(target - from) > 0.01 else {
                screen.brightness = target
                finishRamp()
                return
            }
            ramp = Ramp(from: from, to: target, start: CACurrentMediaTime(), duration: duration)
            // Sixty brightness steps a second look continuous.
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let ramp, let screen else {
                stopRamp()
                return
            }
            let t = min(1, (link.targetTimestamp - ramp.start) / ramp.duration)
            // Smoothstep: eases out of one level and into the next.
            let eased = CGFloat(t * t * (3 - 2 * t))
            screen.brightness = ramp.from + (ramp.to - ramp.from) * eased
            if t >= 1 {
                stopRamp()
                finishRamp()
            }
        }

        /// Back at the saved level: the next open saves it again.
        private func finishRamp() {
            if !isOn { savedBrightness = nil }
        }

        /// Also breaks the display link's hold on this view.
        private func stopRamp() {
            displayLink?.invalidate()
            displayLink = nil
            ramp = nil
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
