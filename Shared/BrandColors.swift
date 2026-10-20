import SwiftUI
import UIKit

/// Monero One brand orange, `color.brand` in the design tokens
/// (monero-one-brand/tokens/tokens.json). It is the one action color:
/// buttons, links, selection, progress and pending states. It is the orange
/// of the glass logo art (MoneroSymbol), in Display P3 like the art:
/// #F17F38 in light mode and #DC692A in dark mode (the dark art is darker).
/// Increase Contrast makes it darker on light backgrounds and lighter on
/// dark ones. Use it in place of system orange,
/// which changes with the iOS version (#FF9500, then #FF8D28 on iOS 26).
extension UIColor {
    static let brand = UIColor { traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0x85 / 255, blue: 0x33 / 255, alpha: 1)  // #FF8533
                : UIColor(red: 0xC4 / 255, green: 0x4D / 255, blue: 0, alpha: 1) // #C44D00
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(displayP3Red: 0xDC / 255, green: 0x69 / 255, blue: 0x2A / 255, alpha: 1) // P3 #DC692A
            : UIColor(displayP3Red: 0xF1 / 255, green: 0x7F / 255, blue: 0x38 / 255, alpha: 1) // P3 #F17F38
    }
}

extension Color {
    static let brand = Color(uiColor: .brand)
    /// Top and bottom stops of the brand glyph gradient (AnimatedWalletIcon).
    /// Decorative only: never use them as action colors.
    static let brandHighlight = Color(red: 1, green: 0x85 / 255, blue: 0x33 / 255) // #FF8533
    static let brandShade = Color(red: 0xD9 / 255, green: 0x57 / 255, blue: 0)     // #D95700
    /// `color.brand` and `color.brandPressed` as the tokens give them, in
    /// sRGB. Only for pictures that leave the app and must look the same in
    /// light and dark (the payment link card); UI uses `brand`.
    static let brandToken = Color(red: 1, green: 0x66 / 255, blue: 0)            // #FF6600
    static let brandPressed = Color(red: 0xE6 / 255, green: 0x5C / 255, blue: 0) // #E65C00
}

/// The payment link envelope and its paper card (link-card mockup, final
/// v2). Picture colors, never UI colors: the dark laid paper, the orange
/// wax and liner, the ivory card. Fixed, so the envelope looks the same in
/// light and dark and in the shared picture. The liner and the unit on the
/// card use `brandToken` and `brandPressed`.
enum EnvelopeArt {
    static let pocketTop = Color(rgb: 0x2E2E33)
    static let pocketMiddle = Color(rgb: 0x26262A)
    static let pocketBottom = Color(rgb: 0x202024)
    static let flapTop = Color(rgb: 0x36363C)
    static let flapMiddle = Color(rgb: 0x2D2D32)
    static let flapBottom = Color(rgb: 0x29292E)
    static let flapInside = Color(rgb: 0x26262A)
    static let linerMiddle = Color(rgb: 0xF56200)
    static let waxLight = Color(rgb: 0xFF8A3D)
    static let waxMiddle = Color(rgb: 0xFF6A0A)
    static let waxDeep = Color(rgb: 0xB54500)
    static let waxRing = Color(rgb: 0xF06A10)
    static let waxStamp = Color(rgb: 0xD95400)
    static let waxGlint = Color(rgb: 0xFFC496)
    static let waxShade = Color(rgb: 0x6E2400)
    static let waxShine = Color(rgb: 0xFFE2C4)
    static let crack = Color(rgb: 0x4A1800)
    static let paperLight = Color(rgb: 0xFBF8F1)
    static let paperMiddle = Color(rgb: 0xF3EDE1)
    static let paperDeep = Color(rgb: 0xE9E1D1)
    static let paperEdge = Color(rgb: 0x503C1E)
    static let ink = Color(rgb: 0x1F1F22)
    static let cardLabel = Color(rgb: 0x6E675C)
    static let foilDeep = Color(rgb: 0xB84A00)
    static let foilEnd = Color(rgb: 0xC24E00)
    static let backdropLight = Color(rgb: 0xF1EFEB)
    static let backdropMiddle = Color(rgb: 0xE4E0DA)
    static let backdropDeep = Color(rgb: 0xD6D1C9)
}

private extension Color {
    /// sRGB from 0xRRGGBB.
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension ShapeStyle where Self == Color {
    /// Lets `.brand` go wherever SwiftUI takes a shape style, for example
    /// `.foregroundStyle(.brand)` and `.fill(.brand)`.
    static var brand: Color { Color.brand }
}
