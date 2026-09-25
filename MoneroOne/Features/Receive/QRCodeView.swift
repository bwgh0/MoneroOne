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
                // the modules keep sharp edges at any size (full screen too).
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

// MARK: - Full Screen

extension View {
    /// Tapping this view shows `content` full screen in `QRFullscreenView`.
    /// On iOS 18 and later the page zooms out of this view and back into
    /// it, and a swipe down closes it.
    func opensQRFullscreen(content: String, title: String, amount: Decimal?) -> some View {
        modifier(QRFullscreenPresenter(qrContent: content, title: title, amount: amount))
    }
}

private struct QRFullscreenPresenter: ViewModifier {
    let qrContent: String
    let title: String
    let amount: Decimal?
    @State private var isPresented = false
    @Namespace private var zoomNamespace
    private let zoomID = "qrFullscreen"

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
            .zoomTransitionSource(id: zoomID, in: zoomNamespace)
            .fullScreenCover(isPresented: $isPresented) {
                QRFullscreenView(content: qrContent, title: title, amount: amount)
                    .zoomTransition(sourceID: zoomID, in: zoomNamespace)
            }
    }

    private func open() {
        HapticFeedback.shared.softTick()
        // End editing first (the Receive amount field), so the keyboard
        // does not stay up over the page.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        isPresented = true
    }
}

/// A receive QR code as large as the screen allows, on a white card with the
/// Monero One lockup, so a payer can scan it from arm's length. The screen
/// goes to full brightness while it shows, the way Wallet shows a pass. Like
/// Cake's page it shows no address: the code is the address.
struct QRFullscreenView: View {
    let content: String
    /// What the code points at: "Main Address", a label, or "Subaddress #n".
    /// VoiceOver reads it with the code; the page does not show it.
    let title: String
    /// The amount the code requests, nil for none.
    var amount: Decimal? = nil
    /// VoiceOver starts on the code, not on Close, so the escape gesture
    /// (two-finger Z) closes the page right away: the page takes escape,
    /// and the Close button sits outside the page in the navigation bar.
    @AccessibilityFocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            card
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { Color(.systemGroupedBackground).ignoresSafeArea() }
                // No input on this page. After the Receive amount field has
                // been edited, turning the phone raises a keyboard inset
                // behind the page; ignore it so the card stays centered.
                // Inside the stack: its UIKit container does not pass the
                // modifier down.
                .ignoresSafeArea(.keyboard)
                // VoiceOver's escape (two-finger Z) looks for this among
                // the focused element's ancestors. The stack's UIKit
                // container sits between the page and anything outside
                // it, so the action goes on the page itself.
                .accessibilityAction(.escape) { dismiss() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        closeButton
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .horizontalBarsOnDuo()
                // After the zoom settles: VoiceOver puts focus on the first
                // element of a new screen when the presentation ends, which
                // would override a focus set on appear.
                .task {
                    try? await Task.sleep(for: .milliseconds(700))
                    codeFocused = true
                }
        }
        .background(FullBrightness())
    }

    /// Lockup, code and captions stacked; side by side when the screen is
    /// short (landscape), so the code keeps most of the height. Side by
    /// side, the card hugs the code instead of stretching to the width cap.
    private var card: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 24) {
                    code
                    VStack(alignment: .leading, spacing: 16) {
                        lockup
                        amountCaption
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                }
            } else {
                VStack(spacing: 16) {
                    lockup
                    code
                    amountCaption
                }
                .frame(maxWidth: 448)
            }
        }
        .padding(16)
        .background {
            // White in dark mode too: a QR code needs dark modules on a
            // light field to scan.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
                .shadow(
                    color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
        // Text on the white card takes its light-mode colors.
        .environment(\.colorScheme, .light)
    }

    private var code: some View {
        QRCodeView(content: content)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR code for Monero address")
            .accessibilityValue(title)
            .accessibilityIdentifier("qrFullscreen.qrCode")
            .accessibilityFocused($codeFocused)
    }

    private var lockup: some View {
        HStack(spacing: 8) {
            Image("MoneroLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            Text(verbatim: "Monero One")
                .font(.headline.bold())
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var amountCaption: some View {
        if let amount {
            Text("\(XMRFormatter.format(amount)) XMR")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) {
                dismiss()
            }
            .accessibilityIdentifier("qrFullscreen.close")
        } else {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("qrFullscreen.close")
        }
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

private extension View {
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(sourceID: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}

#Preview {
    QRCodeView(content: "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H")
        .frame(width: 200, height: 200)
        .padding()
        .background(Color.white)
}

#Preview("Full screen") {
    QRFullscreenView(
        content: "monero:888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H?tx_amount=0.5",
        title: "Subaddress #1",
        amount: 0.5
    )
}
