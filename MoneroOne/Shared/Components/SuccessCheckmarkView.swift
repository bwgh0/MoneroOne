import SwiftUI

struct SuccessCheckmarkView: View {
    @State private var showCheck = false
    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 1
    @State private var showConfetti = false

    var body: some View {
        ZStack {
            // Expanding ring burst
            Circle()
                .stroke(Color.green.opacity(ringOpacity), lineWidth: 3)
                .frame(width: 100, height: 100)
                .scaleEffect(ringScale)

            // Checkmark
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .scaleEffect(showCheck ? 1 : 0.3)
                .opacity(showCheck ? 1 : 0)

            // Confetti
            if showConfetti {
                ConfettiView()
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                showCheck = true
            }
            withAnimation(.easeOut(duration: 0.8)) {
                ringScale = 2.0
                ringOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showConfetti = true
            }
        }
    }
}

// MARK: - Confetti

struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []

    static let colors: [Color] = [.orange, .green, .blue, .pink, .purple, .yellow, .mint]
    private static let particleCount = 50

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                ConfettiParticleView(particle: particle)
            }
        }
        .onAppear {
            spawnParticles()
        }
    }

    private func spawnParticles() {
        particles = (0..<Self.particleCount).map { _ in
            ConfettiParticle()
        }

        for i in particles.indices {
            let angle = Double.random(in: 0...(2 * .pi))
            let distance = Double.random(in: 80...200)
            let endX = cos(angle) * distance
            let endY = sin(angle) * distance

            withAnimation(.easeOut(duration: Double.random(in: 0.8...1.4))) {
                particles[i].x = endX
                particles[i].y = endY
                particles[i].rotation = Double.random(in: 0...720)
                particles[i].opacity = 0
            }
        }
    }
}

private struct ConfettiParticleView: View {
    let particle: ConfettiParticle

    var body: some View {
        Group {
            switch particle.shapeType {
            case 0:
                Circle().fill(particle.color)
            case 1:
                Rectangle().fill(particle.color)
            default:
                Triangle().fill(particle.color)
            }
        }
        .frame(width: particle.size, height: particle.size)
        .rotationEffect(Angle(degrees: particle.rotation))
        .offset(x: particle.x, y: particle.y)
        .opacity(particle.opacity)
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGFloat
    let shapeType: Int
    var x: Double = 0
    var y: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1

    init() {
        color = ConfettiView.colors.randomElement() ?? .orange
        size = CGFloat.random(in: 4...10)
        shapeType = Int.random(in: 0...2)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
