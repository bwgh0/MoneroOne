import SwiftUI

// MARK: - Geometry

/// The payment link as an object (link-card mockup, final v2): a sealed
/// envelope of dark paper with the Monero mark in an orange wax seal, and
/// the ivory paper card inside it with the amount. Every part is drawn at
/// the mockup's design size, the envelope 1000 x 680, and its container
/// scales it.
enum Envelope {
    static let width: CGFloat = 1000
    static let height: CGFloat = 680
    static let cornerRadius: CGFloat = 12
    static let flapHeight: CGFloat = 310
    static let sealOrigin = CGPoint(x: 402, y: 207)
    static let sealSide: CGFloat = 196
    static let cardOrigin = CGPoint(x: 60, y: 40)
    static let cardWidth: CGFloat = 880
    static let cardHeight: CGFloat = 600
    /// How far the card slides up out of the pocket: its top band (the
    /// amount and the label) shows, the rest stays in.
    static let cardRise: CGFloat = 363
    /// Where the light sits on the paper and the wax at rest.
    static let restLight = UnitPoint(x: 0.36, y: 0.3)
    /// The sweep's place before and after it plays (off the paper).
    static let sweepStart: CGFloat = -0.35
    static let sweepEnd: CGFloat = 1.35
}

// MARK: - Shapes (design units)

/// The top flap, closed: it hangs from the top edge to the seal.
struct EnvelopeFlapShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 1000, y: 0))
        p.addLine(to: CGPoint(x: 524, y: 290))
        p.addQuadCurve(to: CGPoint(x: 476, y: 290), control: CGPoint(x: 500, y: 305))
        p.closeSubpath()
        return p
    }
}

/// The orange liner inside the flap.
struct EnvelopeLinerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 24, y: 0))
        p.addLine(to: CGPoint(x: 976, y: 0))
        p.addLine(to: CGPoint(x: 516, y: 276))
        p.addQuadCurve(to: CGPoint(x: 484, y: 276), control: CGPoint(x: 500, y: 287))
        p.closeSubpath()
        return p
    }
}

/// The light on the flap's lower edges.
struct EnvelopeFlapEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 476, y: 290))
        p.addQuadCurve(to: CGPoint(x: 524, y: 290), control: CGPoint(x: 500, y: 305))
        p.addLine(to: CGPoint(x: 1000, y: 0))
        return p
    }
}

/// The folds of the pocket: the side flaps meet under the seal, the bottom
/// flap rises to it.
private enum EnvelopeSeam {
    static var sides: Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 468, y: 346))
        p.move(to: CGPoint(x: 1000, y: 0))
        p.addLine(to: CGPoint(x: 532, y: 346))
        return p
    }

    static var bottomShadow: Path {
        var p = Path()
        p.move(to: CGPoint(x: -4, y: 676))
        p.addLine(to: CGPoint(x: 500, y: 326))
        p.addLine(to: CGPoint(x: 1004, y: 676))
        return p
    }

    static var bottomEdge: Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 680))
        p.addLine(to: CGPoint(x: 500, y: 330))
        p.addLine(to: CGPoint(x: 1000, y: 680))
        return p
    }
}

/// The wax, in its 196 x 196 box: a round drop with a rough edge.
struct WaxShape: Shape {
    private static let points: [CGFloat] = [
        191.2, 98, 191.66, 100.68, 191.01, 103.32, 189.65, 105.87, 188.29, 108.36, 187.43, 110.86, 186.92, 113.39, 186.24, 115.88,
        185.01, 118.23, 183.39, 120.45, 181.85, 122.62, 180.71, 124.88, 179.9, 127.22, 179.09, 129.57, 178.17, 131.88, 177.37, 134.25,
        177.02, 136.85, 177.07, 139.72, 176.98, 142.6, 176.11, 145.1, 174.22, 146.98, 171.66, 148.36, 169.06, 149.63, 166.83, 151.08,
        164.91, 152.71, 162.98, 154.31, 160.88, 155.71, 158.75, 157.03, 156.82, 158.53, 155.14, 160.26, 153.46, 162.01, 151.51, 163.44,
        149.31, 164.54, 147.15, 165.65, 145.35, 167.25, 143.92, 169.46, 142.55, 171.87, 140.86, 173.9, 138.76, 175.24, 136.42, 176.15,
        134.15, 177.15, 132.05, 178.57, 130.04, 180.3, 127.98, 182.03, 125.83, 183.64, 123.64, 185.33, 121.48, 187.32, 119.26, 189.42,
        116.85, 191.01, 114.19, 191.53, 111.36, 190.94, 108.53, 189.81, 105.8, 188.86, 103.17, 188.38, 100.57, 188.04, 98, 187.36,
        95.48, 186.19, 93.03, 184.84, 90.63, 183.79, 88.23, 183.15, 85.82, 182.69, 83.44, 182.11, 81.08, 181.49, 78.65, 181.22,
        76.03, 181.56, 73.26, 182.26, 70.51, 182.61, 68.03, 182, 65.92, 180.41, 64.03, 178.37, 62.13, 176.54, 60.07, 175.15,
        57.92, 173.97, 55.83, 172.67, 53.85, 171.22, 51.82, 169.85, 49.61, 168.76, 47.29, 167.79, 45.14, 166.55, 43.37, 164.81,
        41.89, 162.76, 40.3, 160.87, 38.26, 159.48, 35.8, 158.45, 33.36, 157.33, 31.37, 155.74, 29.88, 153.7, 28.56, 151.55,
        26.99, 149.59, 25.05, 147.88, 22.97, 146.22, 20.96, 144.46, 18.97, 142.63, 16.76, 140.87, 14.24, 139.18, 11.81, 137.36,
        10.12, 135.14, 9.59, 132.42, 10.01, 129.4, 10.71, 126.36, 11.12, 123.51, 11.17, 120.82, 11.27, 118.17, 11.78, 115.47,
        12.63, 112.77, 13.41, 110.16, 13.8, 107.66, 13.87, 105.23, 13.97, 102.8, 14.26, 100.39, 14.44, 98, 14.05, 95.6,
        12.98, 93.14, 11.71, 90.59, 11, 88.02, 11.3, 85.53, 12.4, 83.19, 13.63, 80.91, 14.47, 78.58, 14.9, 76.16,
        15.26, 73.71, 15.8, 71.29, 16.4, 68.89, 16.79, 66.38, 16.95, 63.75, 17.24, 61.12, 18.14, 58.74, 19.73, 56.7,
        21.61, 54.86, 23.17, 52.87, 24.18, 50.56, 24.94, 48.05, 25.99, 45.68, 27.6, 43.72, 29.57, 42.05, 31.47, 40.35,
        33.04, 38.38, 34.39, 36.18, 35.75, 33.95, 37.23, 31.79, 38.66, 29.52, 39.89, 26.94, 41.03, 24.12, 42.48, 21.58,
        44.58, 19.88, 47.38, 19.24, 50.52, 19.27, 53.58, 19.34, 56.36, 19.09, 58.98, 18.64, 61.63, 18.36, 64.38, 18.45,
        67.12, 18.68, 69.69, 18.66, 72.1, 18.27, 74.45, 17.78, 76.84, 17.5, 79.25, 17.38, 81.59, 16.99, 83.79, 15.9,
        85.95, 14.18, 88.19, 12.47, 90.57, 11.48, 93.05, 11.42, 95.54, 11.85, 98, 12.13, 100.46, 11.93, 102.95, 11.44,
        105.47, 11.02, 108.01, 10.75, 110.59, 10.4, 113.27, 9.79, 116.01, 9.11, 118.72, 8.91, 121.23, 9.62, 123.51, 11.11,
        125.7, 12.75, 127.98, 13.97, 130.44, 14.69, 132.93, 15.36, 135.23, 16.48, 137.26, 18.15, 139.17, 19.98, 141.18, 21.54,
        143.39, 22.72, 145.71, 23.77, 147.98, 24.91, 150.25, 26.08, 152.72, 27.03, 155.53, 27.65, 158.45, 28.24, 160.98, 29.37,
        162.72, 31.4, 163.65, 34.19, 164.22, 37.23, 164.9, 40.03, 165.87, 42.5, 166.89, 44.87, 167.69, 47.37, 168.25, 49.96,
        168.87, 52.46, 169.79, 54.71, 170.92, 56.82, 171.93, 58.99, 172.62, 61.31, 173.22, 63.65, 174.24, 65.78, 175.98, 67.64,
        178.16, 69.4, 180.12, 71.32, 181.31, 73.54, 181.78, 75.98, 182.09, 78.45, 182.74, 80.83, 183.84, 83.15, 185.07, 85.48,
        186.16, 87.88, 187.2, 90.34, 188.44, 92.83, 189.92, 95.37
    ]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let values = Self.points
        p.move(to: CGPoint(x: values[0], y: values[1]))
        var i = 2
        while i + 1 < values.count {
            p.addLine(to: CGPoint(x: values[i], y: values[i + 1]))
            i += 2
        }
        p.closeSubpath()
        return p
    }
}

/// Where the seal breaks, in the seal's box.
private let crackPoints: [CGFloat] = [
    -6, 95, 14, 100, 26, 94, 40, 103, 54, 96, 67, 105, 81, 98, 94, 107,
    107, 99, 121, 106, 135, 97, 149, 104, 162, 95, 177, 101, 202, 94,
]

/// The crack through the wax.
struct CrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: crackPoints[0], y: crackPoints[1]))
        var i = 2
        while i + 1 < crackPoints.count {
            p.addLine(to: CGPoint(x: crackPoints[i], y: crackPoints[i + 1]))
            i += 2
        }
        return p
    }
}

/// One half of the broken seal: the lower half stays on the pocket, the
/// upper half lifts with the flap.
struct SealHalfShape: Shape {
    let lower: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: crackPoints[0], y: crackPoints[1]))
        var i = 2
        while i + 1 < crackPoints.count {
            p.addLine(to: CGPoint(x: crackPoints[i], y: crackPoints[i + 1]))
            i += 2
        }
        let edge: CGFloat = lower ? 202 : -6
        p.addLine(to: CGPoint(x: 202, y: edge))
        p.addLine(to: CGPoint(x: -6, y: edge))
        p.closeSubpath()
        return p
    }
}

/// The official Monero mark pressed into the wax, in a 108 x 108 box.
struct MoneroStampShape: Shape {
    private static let base: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 2249.97, y: 32.61))
        p.addCurve(to: CGPoint(x: 32.58, y: 2249.97), control1: CGPoint(x: 1025.55, y: 32.61), control2: CGPoint(x: 32.58, y: 1025.52))
        p.addCurve(to: CGPoint(x: 145.52, y: 2950.36), control1: CGPoint(x: 32.58, y: 2494.72), control2: CGPoint(x: 72.25, y: 2730.14))
        p.addLine(to: CGPoint(x: 808.67, y: 2950.36))
        p.addLine(to: CGPoint(x: 808.67, y: 1084.72))
        p.addLine(to: CGPoint(x: 2249.97, y: 2526.05))
        p.addLine(to: CGPoint(x: 3691.28, y: 1084.72))
        p.addLine(to: CGPoint(x: 3691.28, y: 2950.36))
        p.addLine(to: CGPoint(x: 4354.47, y: 2950.36))
        p.addCurve(to: CGPoint(x: 4467.42, y: 2249.97), control1: CGPoint(x: 4427.75, y: 2730.14), control2: CGPoint(x: 4467.42, y: 2494.72))
        p.addCurve(to: CGPoint(x: 2249.97, y: 32.61), control1: CGPoint(x: 4467.42, y: 1025.52), control2: CGPoint(x: 3474.45, y: 32.61))
        p.move(to: CGPoint(x: 1918.55, y: 2857.41))
        p.addLine(to: CGPoint(x: 1289.55, y: 2228.38))
        p.addLine(to: CGPoint(x: 1289.55, y: 3402.30))
        p.addLine(to: CGPoint(x: 1049.08, y: 3402.30))
        p.addLine(to: CGPoint(x: 808.64, y: 3402.30))
        p.addLine(to: CGPoint(x: 355.20, y: 3402.30))
        p.addCurve(to: CGPoint(x: 2249.94, y: 4467.39), control1: CGPoint(x: 744.45, y: 4040.91), control2: CGPoint(x: 1447.48, y: 4467.39))
        p.addCurve(to: CGPoint(x: 4144.69, y: 3402.30), control1: CGPoint(x: 3052.37, y: 4467.39), control2: CGPoint(x: 3755.47, y: 4040.91))
        p.addLine(to: CGPoint(x: 3691.22, y: 3402.30))
        p.addLine(to: CGPoint(x: 3261.16, y: 3402.30))
        p.addLine(to: CGPoint(x: 3210.34, y: 3402.30))
        p.addLine(to: CGPoint(x: 3210.34, y: 2228.38))
        p.addLine(to: CGPoint(x: 2581.30, y: 2857.41))
        p.addLine(to: CGPoint(x: 2249.94, y: 3188.77))
        p.addLine(to: CGPoint(x: 1918.58, y: 2857.41))
        p.closeSubpath()
        return p
    }()

    func path(in rect: CGRect) -> Path {
        let scale = 108 / 4435.0
        let transform = CGAffineTransform(translationX: -32.5, y: -32.5)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return Self.base.applying(transform)
    }
}

// MARK: - Light

/// One band of light across a part, tilted like the mockup's 98 degree
/// gradient. `center` is the band's middle in the part's own units.
struct EnvelopeSweepBand: View {
    let center: CGFloat
    let halfWidth: CGFloat
    let color: Color

    var body: some View {
        LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: halfWidth * 2, height: 2000)
            .rotationEffect(.degrees(8))
            .offset(x: center - halfWidth, y: -700)
            .allowsHitTesting(false)
    }
}

/// The soft light on the paper; it follows `light` (0...1 in the part).
struct EnvelopeSheen: View {
    let light: UnitPoint
    var strength: Double = 0.08

    var body: some View {
        EllipticalGradient(
            colors: [.white.opacity(strength), .white.opacity(0)],
            center: light,
            startRadiusFraction: 0,
            endRadiusFraction: 0.55
        )
    }
}

// MARK: - Parts

/// The wax seal, 196 x 196: the wax, its raised ring, the mark pressed in
/// it and the light on it.
struct WaxSeal: View {
    var light: UnitPoint = Envelope.restLight
    /// The sweep's place across the envelope, 0...1.
    var sweep: CGFloat = Envelope.sweepStart

    var body: some View {
        ZStack(alignment: .topLeading) {
            WaxShape()
                .fill(RadialGradient(
                    stops: [
                        .init(color: EnvelopeArt.waxLight, location: 0),
                        .init(color: EnvelopeArt.waxMiddle, location: 0.34),
                        .init(color: .brandPressed, location: 0.64),
                        .init(color: EnvelopeArt.waxDeep, location: 1),
                    ],
                    center: UnitPoint(x: 0.42, y: 0.34),
                    startRadius: 0,
                    endRadius: 172
                ))
            ring
            stamp
            shine
        }
        .frame(width: Envelope.sealSide, height: Envelope.sealSide, alignment: .topLeading)
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 5)
    }

    private var ring: some View {
        Circle()
            .stroke(EnvelopeArt.waxRing, lineWidth: 6.5)
            .frame(width: 134, height: 134)
            .shadow(color: EnvelopeArt.waxGlint.opacity(0.6), radius: 0, x: 0, y: -1.6)
            .shadow(color: EnvelopeArt.waxShade.opacity(0.55), radius: 0, x: 0, y: 1.6)
            .offset(x: 31, y: 31)
    }

    private var stamp: some View {
        MoneroStampShape()
            .fill(EnvelopeArt.waxStamp)
            .frame(width: 108, height: 108)
            .shadow(color: EnvelopeArt.waxShade.opacity(0.62), radius: 0, x: 0, y: -1.8)
            .shadow(color: EnvelopeArt.waxGlint.opacity(0.6), radius: 0, x: 0, y: 1.6)
            .offset(x: 44, y: 44)
    }

    private var shine: some View {
        let side = Envelope.sealSide
        let spot = UnitPoint(x: 0.18 + light.x * 0.64, y: 0.14 + light.y * 0.6)
        return ZStack(alignment: .topLeading) {
            RadialGradient(
                colors: [EnvelopeArt.waxShine.opacity(0.42), EnvelopeArt.waxShine.opacity(0)],
                center: spot,
                startRadius: 0,
                endRadius: 39
            )
            EnvelopeSweepBand(
                center: sweep * Envelope.width - Envelope.sealOrigin.x,
                halfWidth: 90,
                color: EnvelopeArt.waxShine.opacity(0.42)
            )
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipShape(WaxShape())
        .blendMode(.screen)
    }
}

/// The crack drawing through the wax, in the seal's box.
struct WaxCrack: View {
    let end: CGFloat
    let glintEnd: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            CrackShape()
                .trim(from: 0, to: end)
                .stroke(EnvelopeArt.crack, style: StrokeStyle(lineWidth: 2.8, lineJoin: .round))
            CrackShape()
                .trim(from: 0, to: glintEnd)
                .stroke(EnvelopeArt.waxGlint.opacity(0.6), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                .offset(y: 2.2)
        }
        .frame(width: Envelope.sealSide, height: Envelope.sealSide, alignment: .topLeading)
        .mask(WaxShape())
    }
}

/// The pocket's soft shadow on the page.
struct EnvelopeShadow: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Envelope.cornerRadius)
        ZStack {
            shape
                .fill(Color.black)
                .padding(12)
                .shadow(color: .black.opacity(0.5), radius: 23, x: 0, y: 26)
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 4)
        }
        .frame(width: Envelope.width, height: Envelope.height)
    }
}

/// The front of the pocket: dark laid paper with its folds.
struct EnvelopePocket: View {
    var light: UnitPoint = Envelope.restLight
    var sweep: CGFloat = Envelope.sweepStart

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Envelope.cornerRadius)
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(
                stops: [
                    .init(color: EnvelopeArt.pocketTop, location: 0),
                    .init(color: EnvelopeArt.pocketMiddle, location: 0.55),
                    .init(color: EnvelopeArt.pocketBottom, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            seams
            EnvelopeSheen(light: light)
            EnvelopeSweepBand(center: sweep * Envelope.width, halfWidth: 160, color: .white.opacity(0.09))
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1.5))
    }

    private var seams: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeSeam.sides.stroke(Color.black.opacity(0.42), lineWidth: 3)
            EnvelopeSeam.sides.stroke(Color.white.opacity(0.05), lineWidth: 1.4)
                .offset(y: 2.4)
            EnvelopeSeam.bottomShadow.stroke(Color.black.opacity(0.55), lineWidth: 7)
                .blur(radius: 3)
                .offset(y: -4)
            EnvelopeSeam.bottomEdge.fill(Color.white.opacity(0.028))
            EnvelopeSeam.bottomEdge.stroke(Color.white.opacity(0.1), lineWidth: 1.6)
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
    }
}

/// The flap's outside, as it hangs when the envelope is closed.
struct EnvelopeFlapOutside: View {
    var light: UnitPoint = Envelope.restLight
    var sweep: CGFloat = Envelope.sweepStart

    var body: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeFlapShape().fill(LinearGradient(
                stops: [
                    .init(color: EnvelopeArt.flapTop, location: 0),
                    .init(color: EnvelopeArt.flapMiddle, location: 0.6),
                    .init(color: EnvelopeArt.flapBottom, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            EnvelopeSheen(light: light)
            EnvelopeSweepBand(center: sweep * Envelope.width, halfWidth: 160, color: .white.opacity(0.09))
            EnvelopeFlapEdge().stroke(Color.white.opacity(0.13), lineWidth: 3)
        }
        .frame(width: Envelope.width, height: Envelope.flapHeight, alignment: .topLeading)
        .clipShape(EnvelopeFlapShape())
        .shadow(color: .black.opacity(0.5), radius: 4.5, x: 0, y: 7)
    }
}

/// The flap's inside: the orange liner, seen once the flap lifts.
struct EnvelopeFlapInside: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeFlapShape().fill(EnvelopeArt.flapInside)
            EnvelopeLinerShape().fill(LinearGradient(
                stops: [
                    .init(color: .brandToken, location: 0),
                    .init(color: EnvelopeArt.linerMiddle, location: 0.55),
                    .init(color: .brandPressed, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
        .frame(width: Envelope.width, height: Envelope.flapHeight, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 4.5, x: 0, y: 7)
    }
}

/// The flap turns on its top edge; past 90 degrees its inside shows.
private extension View {
    func flapTurn(_ degrees: Double) -> some View {
        rotation3DEffect(.degrees(degrees), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.625)
    }
}

/// The envelope's front, from the pocket to the seal. Sealed by default.
struct EnvelopeFront<Foil: View>: View {
    var flapAngle: Double = 0
    /// Past 90 degrees: the flap's outside hides, its inside shows behind
    /// the card.
    var flapLifted = false
    /// The seal broke: its lower half stays on the pocket, its upper half
    /// lifts with the flap.
    var sealBroken = false
    var crackEnd: CGFloat = 0
    var crackGlintEnd: CGFloat = 0
    var light: UnitPoint = Envelope.restLight
    var sweep: CGFloat = Envelope.sweepStart
    /// Drawn on the pocket, under the flap (the shared picture's amount).
    @ViewBuilder var foil: () -> Foil

    var body: some View {
        let seal = Envelope.sealOrigin
        ZStack(alignment: .topLeading) {
            EnvelopePocket(light: light, sweep: sweep)
            foil()
            WaxSeal(light: light, sweep: sweep)
                .clipShape(SealHalfShape(lower: true))
                .offset(x: seal.x, y: seal.y)
                .opacity(sealBroken ? 1 : 0)
            flap
            if !sealBroken {
                WaxSeal(light: light, sweep: sweep)
                    .offset(x: seal.x, y: seal.y)
                WaxCrack(end: crackEnd, glintEnd: crackGlintEnd)
                    .offset(x: seal.x, y: seal.y)
            }
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
    }

    private var flap: some View {
        let seal = Envelope.sealOrigin
        return ZStack(alignment: .topLeading) {
            EnvelopeFlapOutside(light: light, sweep: sweep)
            if sealBroken {
                WaxSeal(light: light, sweep: sweep)
                    .clipShape(SealHalfShape(lower: false))
                    .offset(x: seal.x, y: seal.y)
            }
        }
        .frame(width: Envelope.width, height: Envelope.flapHeight, alignment: .topLeading)
        .flapTurn(flapAngle)
        .opacity(flapLifted ? 0 : 1)
    }
}

extension EnvelopeFront where Foil == EmptyView {
    init(
        flapAngle: Double = 0,
        flapLifted: Bool = false,
        sealBroken: Bool = false,
        crackEnd: CGFloat = 0,
        crackGlintEnd: CGFloat = 0,
        light: UnitPoint = Envelope.restLight,
        sweep: CGFloat = Envelope.sweepStart
    ) {
        self.init(
            flapAngle: flapAngle,
            flapLifted: flapLifted,
            sealBroken: sealBroken,
            crackEnd: crackEnd,
            crackGlintEnd: crackGlintEnd,
            light: light,
            sweep: sweep,
            foil: { EmptyView() }
        )
    }
}

/// Behind the card: the shadow and the flap's inside.
struct EnvelopeBack: View {
    var flapAngle: Double = 0
    var flapLifted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeShadow()
            EnvelopeFlapInside()
                .flapTurn(flapAngle)
                .opacity(flapLifted ? 1 : 0)
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
    }
}

// MARK: - The paper card

/// What the paper card shows: the amount, with "XMR" after it unless it is
/// a fiat amount.
struct EnvelopeCardAmount: Equatable {
    let text: String
    let showsUnit: Bool
}

/// The ivory card inside the envelope, 880 x 600: the amount and "PAYMENT
/// LINK" in its top band, the rest blank stock.
struct EnvelopePaperCard: View {
    let amount: EnvelopeCardAmount
    var sweep: CGFloat = Envelope.sweepStart

    static let numberSize: CGFloat = 140
    static let unitSize: CGFloat = 140 * 0.42
    static let maxLineWidth: CGFloat = 760
    static let minimumScale: CGFloat = 0.4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Envelope.cornerRadius)
        ZStack(alignment: .topLeading) {
            shape.fill(EllipticalGradient(
                stops: [
                    .init(color: EnvelopeArt.paperLight, location: 0),
                    .init(color: EnvelopeArt.paperMiddle, location: 0.6),
                    .init(color: EnvelopeArt.paperDeep, location: 1),
                ],
                center: UnitPoint(x: 0.3, y: 0.1),
                startRadiusFraction: 0,
                endRadiusFraction: 1.2
            ))
            amountLine
            label
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .offset(y: Envelope.cardHeight - 119)
            EnvelopeSweepBand(center: sweep * Envelope.cardWidth, halfWidth: 141, color: .white.opacity(0.7))
                .blendMode(.softLight)
        }
        .frame(width: Envelope.cardWidth, height: Envelope.cardHeight, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(EnvelopeArt.paperEdge.opacity(0.14), lineWidth: 1))
    }

    /// The scale that fits the amount line in 760 of the card's 880,
    /// never under 0.4 (`minimumScaleFactor`).
    private var scale: CGFloat {
        let number = PaymentLinkCard.textWidth(amount.text, font: PaymentLinkCard.numberFont(size: Self.numberSize, weight: .bold), tracking: 0)
        var width = number
        if amount.showsUnit {
            width += 0.12 * Self.unitSize
                + PaymentLinkCard.textWidth("XMR", font: PaymentLinkCard.roundedFont(size: Self.unitSize, weight: .bold), tracking: 0)
        }
        guard width > Self.maxLineWidth else { return 1 }
        return max(Self.minimumScale, Self.maxLineWidth / width)
    }

    private var amountLine: some View {
        let scale = self.scale
        let size = Self.numberSize * scale
        return HStack(alignment: .firstTextBaseline, spacing: 0.12 * Self.unitSize * scale) {
            Text(verbatim: amount.text)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(EnvelopeArt.ink)
            if amount.showsUnit {
                Text(verbatim: "XMR")
                    .font(.system(size: Self.unitSize * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brandPressed)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .shadow(color: .white.opacity(0.9), radius: 0, x: 0, y: 1.6)
        .shadow(color: .black.opacity(0.28), radius: 0, x: 0, y: -1)
        .frame(width: Envelope.cardWidth)
        .offset(y: 58 - PaymentLinkCard.boxOverhang(size: size, weight: .bold))
    }

    private var label: some View {
        Text("Payment Link")
            .textCase(.uppercase)
            .font(.system(size: 26, weight: .bold))
            .tracking(26 * 0.34)
            .foregroundStyle(EnvelopeArt.cardLabel)
            .lineLimit(1)
            .frame(width: Envelope.cardWidth, height: 30)
            .offset(y: 234)
    }
}

// MARK: - The claim sheet's hero

/// The claim sheet's hero, 338 x 280 pt. The envelope comes in sealed.
/// When `isOpen` turns true (the check found money: Waiting or Ready), the
/// seal cracks, the flap lifts, the envelope settles lower and the paper
/// card slides up with the amount. It stays in the open envelope.
///
/// Times from the mockup (final-anim.html), t0 = the crack, 0.42 s after
/// the entrance at the earliest: the crack 0.12 s and softTick; the flap
/// at t0 + 0.14 (stepForward); the card at t0 + 0.40 (celebrate); the
/// success haptic and `onLand` at t0 + 0.68; one light sweep at t0 + 0.88
/// (1.2 s). Reduce Motion: one cross-fade (0.35 s) to the open envelope,
/// the success haptic at its middle; no softTick, travel, scale or sweep.
struct PaymentLinkEnvelopeHero: View {
    let isOpen: Bool
    let amount: EnvelopeCardAmount
    /// The card reached the top: the rest of the sheet comes in.
    var onLand: () -> Void = {}

    static let size = CGSize(width: 338, height: 280)
    /// Points per design unit: the mockup draws the envelope at 0.8 of a
    /// 1000 unit frame, 338 pt wide.
    private static let unit: CGFloat = 0.8 * 0.338
    private static let origin = CGPoint(x: 33.8, y: 48.06)
    /// The envelope settles this much lower, so the open flap stays in the frame.
    private static let drop: CGFloat = 48.06
    /// The sheet settles before the envelope comes in.
    private static let settle: Double = 0.3
    /// The earliest crack, after the entrance begins.
    private static let crackDelay: Double = 0.42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var enteredAt: Date?
    @State private var crackEnd: CGFloat = 0
    @State private var crackGlintEnd: CGFloat = 0
    @State private var sealBroken = false
    @State private var flapAngle: Double = 0
    @State private var flapLifted = false
    @State private var dropped = false
    @State private var cardOut = false
    @State private var sweep: CGFloat = Envelope.sweepStart
    @State private var fade: Double = 1
    @State private var openTask: Task<Void, Never>?

    var body: some View {
        envelope
            .scaleEffect(Self.unit, anchor: .topLeading)
            .offset(x: Self.origin.x, y: Self.origin.y + (dropped ? Self.drop : 0))
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .scaleEffect(entered || reduceMotion ? 1 : 0.4)
            // One layer, so a fade never shows the card through the pocket.
            .compositingGroup()
            .opacity(entered ? fade : 0)
            .accessibilityHidden(true)
            .task { await enter() }
            .onChange(of: isOpen, initial: true) { _, open in
                if open { scheduleOpen() }
            }
            .onDisappear { openTask?.cancel() }
    }

    private var envelope: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeBack(flapAngle: flapAngle, flapLifted: flapLifted)
            EnvelopePaperCard(amount: amount, sweep: sweep)
                .offset(x: Envelope.cardOrigin.x, y: Envelope.cardOrigin.y - (cardOut ? Envelope.cardRise : 0))
            EnvelopeFront(
                flapAngle: flapAngle,
                flapLifted: flapLifted,
                sealBroken: sealBroken,
                crackEnd: crackEnd,
                crackGlintEnd: crackGlintEnd,
                sweep: sweep
            )
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
    }

    private func enter() async {
        guard await pause(Self.settle) else { return }
        enteredAt = .now
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.35)
            : .spring(response: 0.8, dampingFraction: 0.7)
        withAnimation(animation) { entered = true }
    }

    private func scheduleOpen() {
        guard openTask == nil else { return }
        openTask = Task { @MainActor in
            while enteredAt == nil {
                guard await pause(0.05) else { return }
            }
            let wait = Self.crackDelay - Date.now.timeIntervalSince(enteredAt ?? .now)
            if wait > 0 {
                guard await pause(wait) else { return }
            }
            if reduceMotion {
                await crossFadeOpen()
            } else {
                await open()
            }
        }
    }

    private func open() async {
        HapticFeedback.shared.softTick()
        withAnimation(.easeOut(duration: 0.12)) { crackEnd = 1 }
        guard await pause(0.02) else { return }
        withAnimation(.easeOut(duration: 0.12)) { crackGlintEnd = 1 }
        guard await pause(0.12) else { return }

        // t0 + 0.14: the flap lifts and the envelope settles lower.
        sealBroken = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            flapAngle = 180
            dropped = true
        }
        guard await pause(0.074) else { return }
        flapLifted = true
        guard await pause(0.186) else { return }

        // t0 + 0.40: the card slides up out of the pocket.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { cardOut = true }
        guard await pause(0.28) else { return }

        // t0 + 0.68: the card is at the top.
        HapticFeedback.shared.transactionSuccess()
        onLand()
        guard await pause(0.2) else { return }

        // t0 + 0.88: one light sweep.
        withAnimation(.easeInOut(duration: 1.2)) { sweep = Envelope.sweepEnd }
    }

    private func crossFadeOpen() async {
        onLand()
        withAnimation(.easeInOut(duration: 0.175)) { fade = 0 }
        guard await pause(0.175) else { return }
        sealBroken = true
        flapAngle = 180
        flapLifted = true
        dropped = true
        cardOut = true
        HapticFeedback.shared.transactionSuccess()
        withAnimation(.easeInOut(duration: 0.175)) { fade = 1 }
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
