import CoreMotion
import SwiftUI

/// The approved Inset + Core card, shared by the reveal and detail sheet.
/// Type is fixed per card width; a long username never shrinks the font.
struct UsernameCard: View {
  let handle: String
  let externalAddress: String
  var still = false
  var claiming = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var light = UsernameCardLight()

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
        RoundedRectangle(cornerRadius: 30 * s).strokeBorder(
          Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 1.5 * s)
        RoundedRectangle(cornerRadius: 30 * s).strokeBorder(Color.brand, lineWidth: 5 * s)
          .mask(alignment: .bottom) { Rectangle().frame(height: 22 * s) }
        if claiming {
          TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase =
              reduceMotion
              ? 0.0
              : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
                / 2.4
            let edge = RoundedRectangle(cornerRadius: 30 * s)
            edge.trim(from: phase, to: min(1, phase + 0.24)).stroke(
              Color.brand, lineWidth: max(1.5, 4 * s))
            if phase + 0.24 > 1 {
              edge.trim(from: 0, to: phase + 0.24 - 1).stroke(
                Color.brand, lineWidth: max(1.5, 4 * s))
            }
          }
        }
      }
      .rotation3DEffect(.degrees(light.x * 3), axis: (x: 0, y: 1, z: 0))
      .rotation3DEffect(.degrees(-light.y * 2), axis: (x: 1, y: 0, z: 0))
    }
    .aspectRatio(1000.0 / 600.0, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(handle), Monero One username card. \(externalAddress)")
    .onAppear { light.setActive(!still && !reduceMotion && scenePhase == .active) }
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

/// The Core edge on Home: a band inside the card's top edge that thins to
/// nothing around the corners (the card shape minus itself moved down).
struct UsernameTopEdge: Shape {
  var cornerRadius: CGFloat = 20
  var thickness: CGFloat = 2
  func path(in rect: CGRect) -> Path {
    let card = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
    return card.subtracting(card.offsetBy(dx: 0, dy: thickness))
  }
}
