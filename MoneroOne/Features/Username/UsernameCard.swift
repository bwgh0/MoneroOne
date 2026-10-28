import CoreMotion
import SwiftUI

/// The approved Inset + Core card, shared by the reveal and detail sheet.
/// Type is fixed per card width; a long username never shrinks the font.
struct UsernameCard: View {
  let handle: String
  let externalAddress: String
  var still = false
  /// The claim edge, while the claim runs and until the ring has closed.
  var edge: ClaimEdge?
  /// The claim's moment: the card pops, the ring fades, a glow blooms under
  /// the card and one shine sweeps across it.
  var celebrates = false
  /// The confirm step: the glow and the shine wait, hidden, before the claim.
  var awaitsClaim = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var light = UsernameCardLight()
  @State private var pops = false
  @State private var ringOpacity = 1.0
  @State private var glow = Glow.off
  @State private var shine = 0.0

  /// The orange edge of a claim. It laps the card from `start`. From `close`
  /// on, its tail eases to a stop and its head runs on until it is a full ring.
  struct ClaimEdge: Equatable {
    var start: Date
    var close: Date?
    /// One lap per turn of the brand spinner's outer ring (`spinnerOuter`).
    static let lap = 1.5
    /// The ring closes like Send's circle draws itself (`draw`).
    static let closing = 0.4
    static let length = 0.24
    /// The edge starts at 12 o'clock, as Send's circle does. The card's
    /// path starts at 3 o'clock and runs clockwise.
    static let origin = 0.75
  }
  /// `heroGlow` under the card: `bloom` is the art's low state, `rest` its high one.
  private enum Glow {
    case off, bloom, rest
    var opacity: Double { self == .bloom ? 0.6 : self == .rest ? 0.2 : 0 }
    var width: Double { self == .bloom ? 1.1 : 0.75 }
  }

  private var dark: Bool { scheme == .dark }
  private var ink: Color { Color(hexValue: dark ? 0xECEDEF : 0x363C40) }
  private var secondary: Color { Color(hexValue: dark ? 0xADB4B9 : 0x687176) }
  var body: some View {
    GeometryReader { geometry in
      let s = geometry.size.width / 1000
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 30 * s)
          .fill(
            LinearGradient(
              colors: dark
                ? [Color(hexValue: 0x343B3F), Color(hexValue: 0x262C30), Color(hexValue: 0x1A2025)]
                : [
                  Color(hexValue: 0xF0F2F2), Color(hexValue: 0xE4E7E8), Color(hexValue: 0xD5DADD),
                ],
              startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          // Only the card body casts the shadow. The flat mark and the text never do.
          .shadow(color: .black.opacity(dark ? 0.35 : 0.15), radius: 14 * s, y: 12 * s)
        // Core's darker underside: a lip just below the bottom edge.
        RoundedRectangle(cornerRadius: 30 * s).offset(y: 3 * s)
          .subtracting(RoundedRectangle(cornerRadius: 30 * s))
          .fill(Color(hexValue: dark ? 0xA5410B : 0xB74C17))
        RoundedRectangle(cornerRadius: 18 * s)
          .fill(
            LinearGradient(
              colors: [
                Color.black.opacity(dark ? 0.1 : 0.025), Color.white.opacity(dark ? 0.01 : 0.14),
              ], startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 18 * s).strokeBorder(
              Color.black.opacity(dark ? 0.25 : 0.1), lineWidth: s * 2)
          )
          .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 18 * s).strokeBorder(
              Color.white.opacity(dark ? 0.08 : 0.5), lineWidth: s * 2
            )
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
          }
          .padding(44 * s)
        RadialGradient(
          colors: [Color.white.opacity(0.12), .clear],
          center: UnitPoint(x: 0.3 + light.x * 0.2, y: 0.18 + light.y * 0.2), startRadius: 0,
          endRadius: geometry.size.width * 0.7
        )
        .clipShape(RoundedRectangle(cornerRadius: 30 * s))
        Image("MoneroMark").resizable().scaledToFit().frame(width: 48 * s, height: 48 * s).offset(
          x: 87 * s, y: 87 * s)
        Text(verbatim: "MONERO ONE").font(.system(size: 17 * s, weight: .medium)).tracking(2 * s)
          .foregroundStyle(secondary).frame(width: 824 * s, alignment: .trailing).offset(
            x: 88 * s, y: 103 * s)
        (Text(verbatim: "@").foregroundColor(.brand) + Text(verbatim: handle).foregroundColor(ink))
          .font(.system(size: 55 * s, weight: .semibold)).tracking(-1.8 * s)
          .lineLimit(1).offset(x: 88 * s, y: 258 * s)
        Text(verbatim: externalAddress).font(.system(size: 38 * s, weight: .regular)).tracking(
          -0.5 * s
        )
        .foregroundStyle(secondary).lineLimit(1).offset(x: 88 * s, y: 338 * s)
        HStack {
          Rectangle().frame(width: 28 * s, height: 4 * s)
          Spacer()
          Rectangle().frame(width: 28 * s, height: 4 * s)
        }.foregroundStyle(.brand).frame(width: 824 * s).offset(x: 88 * s, y: 508 * s)
        // Core's orange underside: a band inside the bottom edge that thins
        // to nothing around the corners (the card shape minus itself moved up).
        RoundedRectangle(cornerRadius: 30 * s)
          .subtracting(RoundedRectangle(cornerRadius: 30 * s).offset(y: -5 * s))
          .fill(Color.brand)
        RoundedRectangle(cornerRadius: 30 * s).strokeBorder(
          Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 1.5 * s)
        if let edge {
          let ring = RoundedRectangle(cornerRadius: 30 * s)
          let width = max(1.5, 4 * s)
          if celebrates {
            ring.stroke(Color.brand, lineWidth: width).opacity(ringOpacity)
          } else if reduceMotion {
            // No lap: the edge stands still, then the full ring fades in.
            ZStack {
              if edge.close == nil {
                ring.trim(from: ClaimEdge.origin, to: ClaimEdge.origin + ClaimEdge.length).stroke(
                  Color.brand, lineWidth: width)
              } else {
                ring.stroke(Color.brand, lineWidth: width)
              }
            }
            .animation(.easeInOut(duration: 0.35), value: edge.close)
          } else {
            ClaimEdgeRing(edge: edge, cornerRadius: 30 * s, lineWidth: width)
          }
        }
        // `heroShine`: one white band, clipped to the card. It waits off the
        // card from the confirm step, so neither the claim nor the pop builds it.
        if (edge != nil || awaitsClaim) && !reduceMotion {
          LinearGradient(
            colors: [.clear, .white.opacity(0.3), .white.opacity(0.6), .white.opacity(0.3), .clear],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: geometry.size.width * 0.35)
          .blur(radius: 8)
          .offset(x: geometry.size.width * (shine * 1.35 - 0.35))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .clipShape(RoundedRectangle(cornerRadius: 30 * s))
          .allowsHitTesting(false)
        }
      }
      .rotation3DEffect(.degrees(light.x * 3), axis: (x: 0, y: 1, z: 0))
      .rotation3DEffect(.degrees(-light.y * 2), axis: (x: 1, y: 0, z: 0))
    }
    .aspectRatio(1000.0 / 600.0, contentMode: .fit)
    // The pop: the card grows a little (`stepForward`) and settles (`celebrate`).
    .keyframeAnimator(initialValue: 1.0, trigger: pops) { content, scale in
      content.scaleEffect(scale)
    } keyframes: { _ in
      KeyframeTrack {
        SpringKeyframe(1.04, duration: 0.15, spring: Spring(response: 0.3, dampingRatio: 0.85))
        SpringKeyframe(1, spring: Spring(response: 0.5, dampingRatio: 0.7))
      }
    }
    // `heroGlow`, on the card's bottom edge and behind it.
    .background(alignment: .bottom) {
      if edge != nil || awaitsClaim {
        GeometryReader { geometry in
          Ellipse().fill(Color.brand)
            .frame(width: geometry.size.width * 0.7, height: geometry.size.height * 0.15)
            .blur(radius: 25)
            .scaleEffect(x: glow.width)
            .opacity(glow.opacity)
            .position(x: geometry.size.width / 2, y: geometry.size.height)
        }
        .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(handle), Monero One username card. \(externalAddress)")
    .onAppear {
      light.setActive(!still && !reduceMotion && scenePhase == .active)
      if celebrates { celebrate() }
    }
    .onChange(of: celebrates) { _, value in if value { celebrate() } }
    .onDisappear { light.setActive(false) }
    .onChange(of: scenePhase) { _, phase in
      light.setActive(!still && !reduceMotion && phase == .active)
    }
    .onChange(of: reduceMotion) { _, value in
      light.setActive(!still && !value && scenePhase == .active)
    }
    .onChange(of: still) { _, value in
      light.setActive(!value && !reduceMotion && scenePhase == .active)
    }
  }
  /// The moment, once. Reduce Motion: the ring and the glow only fade.
  private func celebrate() {
    let fade = Animation.easeInOut(duration: 0.35)
    if reduceMotion {
      ringOpacity = 0
      withAnimation(fade) { glow = .rest }
      return
    }
    pops.toggle()
    withAnimation(fade) { ringOpacity = 0 }
    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { glow = .bloom } completion: {
      // The glow rests at the art's high state, on the float's curve.
      withAnimation(.easeInOut(duration: 2.5)) { glow = .rest }
    }
    withAnimation(.easeInOut(duration: 1.2)) { shine = 1 }
  }
}

/// The claim edge in Core Animation: the lap and the close run on the
/// render server, so main-thread work while the claim runs (the wallet,
/// the Keychain, the result's layout) never stops the edge.
private struct ClaimEdgeRing: UIViewRepresentable {
  let edge: UsernameCard.ClaimEdge
  let cornerRadius: CGFloat
  let lineWidth: CGFloat
  func makeUIView(context: Context) -> RingView { RingView() }
  func updateUIView(_ view: RingView, context: Context) {
    view.update(edge: edge, cornerRadius: cornerRadius, lineWidth: lineWidth)
  }

  final class RingView: UIView {
    private let ring = CAShapeLayer()
    private var shown: UsernameCard.ClaimEdge?
    private var cornerRadius: CGFloat = 0
    private var laidOut = CGRect.zero
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      ring.fillColor = nil
      ring.strokeStart = 0
      ring.strokeEnd = 0
      layer.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func update(edge: UsernameCard.ClaimEdge, cornerRadius: CGFloat, lineWidth: CGFloat) {
      ring.strokeColor = UIColor.brand.resolvedColor(with: traitCollection).cgColor
      ring.lineWidth = lineWidth
      guard edge != shown || cornerRadius != self.cornerRadius else { return }
      shown = edge
      self.cornerRadius = cornerRadius
      laidOut = .zero
      setNeedsLayout()
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      guard bounds != laidOut, bounds.width > 0, let edge = shown else { return }
      laidOut = bounds
      ring.frame = bounds
      // The card's path three times over, so the edge never wraps at its end.
      let card = RoundedRectangle(cornerRadius: cornerRadius).path(in: bounds).cgPath
      let path = CGMutablePath()
      for _ in 0..<3 { path.addPath(card) }
      ring.path = path
      animate(edge)
    }
    /// Fractions of the threefold path for a span in laps from the trim origin.
    private func stroke(_ laps: Double) -> Double { laps / 3 }
    private func animate(_ edge: UsernameCard.ClaimEdge) {
      typealias Edge = UsernameCard.ClaimEdge
      ring.removeAllAnimations()
      let now = ring.convertTime(CACurrentMediaTime(), from: nil)
      let speed = 1 / Edge.lap
      guard let close = edge.close else {
        // The lap: both ends at one speed, one lap per `lap`, from the start.
        let from = Edge.origin, length = Edge.length
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = stroke(from)
        tail.toValue = stroke(from + 1)
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = stroke(from + length)
        head.toValue = stroke(from + length + 1)
        let lap = CAAnimationGroup()
        lap.animations = [tail, head]
        lap.duration = Edge.lap
        lap.repeatCount = .infinity
        lap.beginTime = now - Date().timeIntervalSince(edge.start)
        ring.add(lap, forKey: "edge")
        return
      }
      // The close: the tail eases to a stop; the head keeps its speed at
      // first and stops a lap ahead of the tail (the Hermite curve).
      let closeTime = max(0, close.timeIntervalSince(edge.start))
      let base = (Edge.origin + closeTime * speed).truncatingRemainder(dividingBy: 1)
      let carry = speed * Edge.closing
      let headFrom = base + Edge.length, headTo = base + carry / 2 + 1
      let tail = CABasicAnimation(keyPath: "strokeStart")
      tail.fromValue = stroke(base)
      tail.toValue = stroke(base + carry / 2)
      tail.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
      let head = CABasicAnimation(keyPath: "strokeEnd")
      head.fromValue = stroke(headFrom)
      head.toValue = stroke(headTo)
      head.timingFunction = CAMediaTimingFunction(
        controlPoints: 1 / 3, Float(carry / (3 * (headTo - headFrom))), 2 / 3, 1)
      let closing = CAAnimationGroup()
      closing.animations = [tail, head]
      closing.duration = Edge.closing
      closing.beginTime = now - max(0, Date().timeIntervalSince(close))
      closing.fillMode = .both
      ring.strokeStart = stroke(base + carry / 2)
      ring.strokeEnd = stroke(headTo)
      ring.add(closing, forKey: "edge")
    }
  }
}

@MainActor
private final class UsernameCardLight: ObservableObject {
  @Published var x = 0.0
  @Published var y = 0.0
  private let motion = CMMotionManager()
  private var initial: (Double, Double)?
  func setActive(_ active: Bool) {
    guard active, motion.isDeviceMotionAvailable else {
      motion.stopDeviceMotionUpdates()
      initial = nil
      x = 0
      y = 0
      return
    }
    guard !motion.isDeviceMotionActive else { return }
    motion.deviceMotionUpdateInterval = 1.0 / 30
    motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
      guard let self, let attitude = data?.attitude else { return }
      if self.initial == nil { self.initial = (attitude.roll, attitude.pitch) }
      guard let initial = self.initial else { return }
      self.x = max(-1, min(1, (attitude.roll - initial.0) * 2))
      self.y = max(-1, min(1, (attitude.pitch - initial.1) * 2))
    }
  }
  deinit { motion.stopDeviceMotionUpdates() }
}

extension Color {
  fileprivate init(hexValue: UInt32) {
    self.init(
      red: Double((hexValue >> 16) & 255) / 255, green: Double((hexValue >> 8) & 255) / 255,
      blue: Double(hexValue & 255) / 255)
  }
}

/// The Core edge on Home: a band inside the card's bottom edge that thins
/// to nothing around the corners (the card shape minus itself moved up).
struct UsernameBottomEdge: Shape {
  var cornerRadius: CGFloat = 20
  var thickness: CGFloat = 2
  func path(in rect: CGRect) -> Path {
    let card = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
    return card.subtracting(card.offsetBy(dx: 0, dy: -thickness))
  }
}
