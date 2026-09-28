import QuartzCore
import SwiftUI

struct AnimatedMoneroLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var shineOffset: CGFloat = -1.5
    @State private var floating = false

    var size: CGFloat = 240

    private static let floatCurve = Animation.easeInOut(duration: 2.5).repeatForever(autoreverses: true)
    private static let shineCurve = Animation.easeInOut(duration: 1.2)

    private var imageName: String {
        colorScheme == .dark ? "MoneroSymbolDark" : "MoneroSymbol"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main logo
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .scaleEffect(1.15)  // Scale up before clipping for tighter crop
                .clipShape(Circle())
                .overlay {
                    // Shine sweep - clipped to circle so it doesn't extend beyond the logo
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.3),
                                .white.opacity(0.6),
                                .white.opacity(0.3),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.35)
                        .blur(radius: 8)
                        .offset(x: shineOffset * geo.size.width)
                        .animation(Self.shineCurve, value: shineOffset)
                    }
                    .clipShape(Circle())
                }
                .offset(y: floating ? -10 : 10)
                .animation(Self.floatCurve, value: floating)

            // Orange glow below - stronger when logo is down
            Ellipse()
                .fill(Color.brand)
                .frame(width: size * 0.7, height: size * 0.15)
                .blur(radius: 25)
                .opacity(floating ? 0.2 : 0.6)
                .scaleEffect(x: floating ? 0.75 : 1.1)
                .animation(Self.floatCurve, value: floating)
                .offset(y: -20)
        }
        .scaleEffect(appeared ? 1.0 : 0.4)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            // Entrance
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                appeared = true
            }

            // Float and shine. These state changes carry no transaction
            // animation: each curve sits on the logo's own modifiers above,
            // through .animation(_:value:). A global
            // withAnimation(repeatForever) here leaked into the PIN
            // keyboard's layout change on a cold launch, and the whole
            // unlock screen then floated with the logo.
            Self.afterOnScreenTime(0.3) { floating = true }
            Self.afterOnScreenTime(0.6) { shineOffset = 1.5 }
        }
    }

    /// Runs `action` after `delay` seconds of on-screen time. It waits in
    /// short main-queue steps and counts each step as 0.1 s at most, so a
    /// main-thread stall does not count. On a cold launch the first keyboard
    /// load stalls the main thread for about 0.6 s while the logo is still
    /// hidden; with a plain asyncAfter the shine then ran as soon as the
    /// logo came into view.
    private static func afterOnScreenTime(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        guard delay > 0 else { return action() }
        let start = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + min(delay, 0.05)) {
            afterOnScreenTime(delay - min(CACurrentMediaTime() - start, 0.1), action)
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.05).ignoresSafeArea()
        AnimatedMoneroLogo(size: 240)
    }
}
