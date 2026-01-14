import SwiftUI

struct AnimatedMoneroLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var shineOffset: CGFloat = -1.5
    @State private var floating = false

    var size: CGFloat = 240

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
                .overlay {
                    // Shine sweep
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
                    }
                    .mask {
                        Image(imageName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .offset(y: floating ? -10 : 10)

            // Orange glow below - stronger when logo is down
            Ellipse()
                .fill(Color.orange)
                .frame(width: size * 0.7, height: size * 0.15)
                .blur(radius: 25)
                .opacity(floating ? 0.2 : 0.6)
                .scaleEffect(x: floating ? 0.75 : 1.1)
                .offset(y: -20)
        }
        .scaleEffect(appeared ? 1.0 : 0.4)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            // Entrance
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                appeared = true
            }

            // Shine sweep
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 1.2)) {
                    shineOffset = 1.5
                }
            }

            // Floating animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(
                    .easeInOut(duration: 2.5)
                    .repeatForever(autoreverses: true)
                ) {
                    floating = true
                }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.05).ignoresSafeArea()
        AnimatedMoneroLogo(size: 240)
    }
}
