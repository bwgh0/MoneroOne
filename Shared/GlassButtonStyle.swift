import SwiftUI

/// Glass-like button style fallback for iOS < 26
struct GlassFallbackButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .light
                        ? Color.white.opacity(0.8)
                        : Color.white.opacity(0.1))
                    .opacity(configuration.isPressed ? 0.6 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// View extension to apply glass button style with iOS version compatibility
extension View {
    /// Applies native .glass style on iOS 26+, custom fallback on earlier versions
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(GlassFallbackButtonStyle())
        }
    }
}
