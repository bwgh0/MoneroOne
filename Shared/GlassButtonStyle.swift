import SwiftUI

/// Glass-like button style fallback for iOS < 26
struct GlassFallbackButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .light
                        ? Color.white
                        : Color.white.opacity(0.1))
                    .shadow(color: .black.opacity(colorScheme == .light ? 0.12 : 0), radius: 4, y: 2)
                    .opacity(configuration.isPressed ? 0.6 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Reports whether the whole window is short: under 720pt including safe
/// areas. True on the iPhone Duo cover (678pt), iPhone SE (667pt), the Duo
/// inner display (669pt) and any phone in landscape. Vertical stacks tuned
/// for 850pt+ phones either cramp the top or leave a hollow middle there.
struct SquatScreenModifier: ViewModifier {
    @Binding var isSquat: Bool
    static let threshold: CGFloat = 720

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Bool.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom < Self.threshold
        } action: { squat in
            if isSquat != squat { isSquat = squat }
        }
    }
}

/// On iPhone Duo the status bar lives in the trailing vertical bar, so the
/// system safe area has ~0 top and 0 leading inset: every screen that relied
/// on the status bar for its top margin ends up jammed into the top-left
/// corner. This adds room through UIKit's `additionalSafeAreaInsets` on the
/// root view controller, because SwiftUI's `safeAreaPadding` never reaches
/// the UIKit-backed `NavigationStack` and `TabView` content. Applied only when
/// a vertical bar is present (trailing inset, no top/leading inset), so
/// regular iPhones, iPad and landscape are untouched.
struct EdgeBreathingRoomModifier: ViewModifier {
    static let extraTop: CGFloat = 28
    static let extraLeading: CGFloat = 12

    func body(content: Content) -> some View {
        content.background(EdgeBreathingRoomInstaller())
    }
}

private struct EdgeBreathingRoomInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) { uiView.apply() }

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            apply()
        }

        func apply() {
            guard let window, let root = window.rootViewController else { return }
            let system = window.safeAreaInsets
            let hasVerticalBar = system.right >= 40 && system.left < 8 && system.top < 20
            let extra = hasVerticalBar
                ? UIEdgeInsets(top: EdgeBreathingRoomModifier.extraTop,
                               left: EdgeBreathingRoomModifier.extraLeading,
                               bottom: 0, right: 0)
                : .zero
            if root.additionalSafeAreaInsets != extra {
                root.additionalSafeAreaInsets = extra
            }
        }
    }
}

extension DynamicViewContent {
    /// System drag-to-reorder for this ForEach's rows on iOS 27: the system
    /// owns the long-press lift, scroll-while-dragging and the drop, and the
    /// enclosing `reorderContainer` gets the difference. A plain ForEach
    /// before iOS 27. Same toolchain gate as `horizontalBarsOnDuo()`.
    @ViewBuilder
    func systemReorderable() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            self.reorderable()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Keeps a sheet's navigation bar horizontal on iPhone Duo instead of the
    /// trailing vertical bar, so its title stays centered. Apple reserves this
    /// for control-light sheets with a single Cancel/Done button.
    /// `toolbarVerticalBehavior` exists only in the iOS 27.1 SDK (Xcode 27.1,
    /// Swift 6.4). CI still builds with Xcode 26.x, where the symbol does not
    /// exist at all, so the call is gated on the toolchain, not just at runtime.
    @ViewBuilder
    func horizontalBarsOnDuo() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            self.toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Lets `swipeActions` on rows inside this scroll view work on iOS 27,
    /// where they are no longer List-only. Inert before iOS 27. Gated on the
    /// toolchain like `horizontalBarsOnDuo()`: the symbol is missing from the
    /// Xcode 26 SDK CI still builds with.
    @ViewBuilder
    func systemSwipeActionsContainer() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            self.swipeActionsContainer()
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Adds top/leading breathing room on displays whose system safe area
    /// leaves none (iPhone Duo cover and inner display).
    func edgeBreathingRoom() -> some View {
        modifier(EdgeBreathingRoomModifier())
    }

    /// Tracks whether the screen is short (see `SquatScreenModifier`).
    func detectSquatScreen(_ isSquat: Binding<Bool>) -> some View {
        modifier(SquatScreenModifier(isSquat: isSquat))
    }

    /// Filled accent button: native .glassProminent on iOS 26+, bordered
    /// prominent before that.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Caps single-column content (onboarding, unlock, forms) at a phone-like
    /// width and centers it, so regular-width displays (iPad, unfolded iPhone
    /// Duo at ~890pt) don't stretch buttons and text from edge to edge.
    func readableColumn(maxWidth: CGFloat = 480) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
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
