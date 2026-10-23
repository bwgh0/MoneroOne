import SwiftUI

/// The Sent mark. A green circle draws itself from 12 o'clock (token
/// `draw`, 0.4 s). When it closes, the success haptic and the send chime
/// start and the check strokes in two legs (token `checkStroke`): the
/// corner lands on the chime's second note. When the check lands, the
/// ring burst and the confetti of `SuccessCheckmarkView` play.
///
/// Reduce Motion: the circle and the check fade in (0.35 s), with the
/// haptic and the chime at once. No burst, no confetti.
struct SendSuccessMark: View {
    /// The success haptic and the chime: when the circle closes.
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var circleEnd: CGFloat = 0
    @State private var checkEnd: CGFloat = 0
    @State private var markOpacity: Double = 1
    @State private var burstScale: CGFloat = 0.8
    @State private var burstOpacity: Double = 0
    @State private var showsConfetti = false
    @State private var hasPlayed = false

    /// The circle sits where the spinner's outer ring was: 120 pt.
    static let circleDiameter: CGFloat = 120
    static let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            // Today's ring burst, sized so it starts on the drawn circle.
            Circle()
                .stroke(Color.green.opacity(burstOpacity), lineWidth: 3)
                .frame(width: Self.circleDiameter / 0.8, height: Self.circleDiameter / 0.8)
                .scaleEffect(burstScale)

            Circle()
                .trim(from: 0, to: circleEnd)
                .stroke(Color.green, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.circleDiameter, height: Self.circleDiameter)

            SendCheckShape()
                .trim(from: 0, to: checkEnd)
                .stroke(Color.green, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))

            if showsConfetti {
                ConfettiView()
            }
        }
        .frame(width: 160, height: 160)
        .opacity(markOpacity)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        guard !hasPlayed else { return }
        hasPlayed = true

        if reduceMotion {
            circleEnd = 1
            checkEnd = 1
            markOpacity = 0
            withAnimation(.easeInOut(duration: 0.35)) { markOpacity = 1 }
            onClose()
            return
        }

        withAnimation(.easeInOut(duration: 0.4)) { circleEnd = 1 }
        guard await pause(0.4) else { return }

        onClose()
        withAnimation(.linear(duration: 0.09)) { checkEnd = SendCheckShape.cornerFraction }
        guard await pause(0.09) else { return }

        withAnimation(.easeOut(duration: 0.17)) { checkEnd = 1 }
        guard await pause(0.17) else { return }

        // The check landed: today's burst and confetti.
        burstOpacity = 1
        withAnimation(.easeOut(duration: 0.8)) {
            burstScale = 2.0
            burstOpacity = 0
        }
        showsConfetti = true
    }

    /// False when the view went away meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }
}

/// The check of the Sent mark, in its 160 pt box: a short leg down to
/// the corner, then a long leg up.
struct SendCheckShape: Shape {
    private static let start = CGPoint(x: 55, y: 79)
    private static let corner = CGPoint(x: 72, y: 96)
    private static let end = CGPoint(x: 103, y: 63)

    /// Where the corner falls along the whole stroke, 0...1.
    static let cornerFraction: CGFloat = {
        let short = hypot(corner.x - start.x, corner.y - start.y)
        let long = hypot(end.x - corner.x, end.y - corner.y)
        return short / (short + long)
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 160
        let origin = CGPoint(x: rect.midX - 80 * scale, y: rect.midY - 80 * scale)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
        }
        var path = Path()
        path.move(to: point(Self.start))
        path.addLine(to: point(Self.corner))
        path.addLine(to: point(Self.end))
        return path
    }
}
