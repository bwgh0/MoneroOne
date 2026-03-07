import SwiftUI

struct GradientSpinner: View {
    var color: Color = .orange
    var iconName: String = "paperplane.fill"

    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Pulsing background circle
            Circle()
                .fill(color.opacity(0.08))
                .frame(width: 160, height: 160)
                .scaleEffect(pulseScale)

            // Outer ring
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0), color, color.opacity(0)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(outerRotation))

            // Inner ring
            Circle()
                .trim(from: 0, to: 0.4)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0), color.opacity(0.6), color.opacity(0)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(innerRotation))

            // Center icon
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(color)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                outerRotation = 360
            }
            withAnimation(.linear(duration: 2.14).repeatForever(autoreverses: false)) {
                innerRotation = -360
            }
            withAnimation(.easeInOut(duration: 2).repeatForever()) {
                pulseScale = 1.15
            }
        }
    }
}
