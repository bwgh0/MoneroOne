import SwiftUI

struct AnimatedWalletIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var shineOffset: CGFloat = -1.5
    @State private var floating = false

    var size: CGFloat = 120

    private var cornerRadius: CGFloat { size * 0.24 }

    /// Orange tint over `.ultraThinMaterial` reads warm and atmospheric in
    /// dark mode but turns muddy/peach against the light material. Drop the
    /// tint entirely in light mode — the shadow alone defines the tile.
    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.orange.opacity(0.25),
                Color.orange.opacity(0.08),
                Color.clear
            ]
        } else {
            return [.clear, .clear, .clear]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main icon
            ZStack {
                // Background: layered gradient for depth
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: backgroundGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // Inner border for glass edge catch
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.25),
                                .white.opacity(0.05),
                                .clear,
                                .white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )

                // Wallet symbol with gradient
                Image(systemName: "wallet.bifold")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.75, blue: 0.25),
                                .orange,
                                Color(red: 0.9, green: 0.45, blue: 0.15)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .orange.opacity(0.4), radius: 12, y: 4)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .overlay {
                // Shine sweep
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.15),
                            .white.opacity(0.4),
                            .white.opacity(0.15),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .blur(radius: 6)
                    .offset(x: shineOffset * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .offset(y: floating ? -8 : 8)

            // Glow below — orange halo in dark mode for warmth, neutral
            // gray in light mode so the shadow reads as depth rather than
            // peach tint.
            Ellipse()
                .fill(colorScheme == .dark ? Color.orange : Color.black)
                .frame(width: size * 0.6, height: size * 0.06)
                .blur(radius: 16)
                .opacity(floating ? 0.15 : 0.45)
                .scaleEffect(x: floating ? 0.7 : 1.1)
                .offset(y: 6)
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
        Color.black.ignoresSafeArea()
        AnimatedWalletIcon(size: 140)
    }
}
