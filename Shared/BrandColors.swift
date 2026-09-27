import SwiftUI
import UIKit

/// Monero One brand orange, `color.brand` in the design tokens
/// (monero-one-brand/tokens/tokens.json). It is the one action color:
/// buttons, links, selection, progress and pending states. It is #FF6600
/// in light and dark mode. Increase Contrast makes it darker on light
/// backgrounds and lighter on dark ones. Use it in place of system orange,
/// which changes with the iOS version (#FF9500, then #FF8D28 on iOS 26).
extension UIColor {
    static let brand = UIColor { traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0x85 / 255, blue: 0x33 / 255, alpha: 1)  // #FF8533
                : UIColor(red: 0xC4 / 255, green: 0x4D / 255, blue: 0, alpha: 1) // #C44D00
        }
        return UIColor(red: 1, green: 0x66 / 255, blue: 0, alpha: 1) // #FF6600
    }
}

extension Color {
    static let brand = Color(uiColor: .brand)
    /// Top and bottom stops of the brand glyph gradient (AnimatedWalletIcon).
    /// Decorative only: never use them as action colors.
    static let brandHighlight = Color(red: 1, green: 0x85 / 255, blue: 0x33 / 255) // #FF8533
    static let brandShade = Color(red: 0xD9 / 255, green: 0x57 / 255, blue: 0)     // #D95700
}

extension ShapeStyle where Self == Color {
    /// Lets `.brand` go wherever SwiftUI takes a shape style, for example
    /// `.foregroundStyle(.brand)` and `.fill(.brand)`.
    static var brand: Color { Color.brand }
}
