import SwiftUI
import UIKit

/// The picture a shared payment link carries, the "orange pass": one square
/// card, LPLinkMetadata.imageProvider, for the Messages bubble and the share
/// sheet header. Drawn on the sender's phone once per share; nothing loads
/// the link. Fixed colors, so the picture looks the same in light and dark.
/// Sizes are the spec's pixels (MoneroOne-Link-Card-v3.html, option 1).
enum PaymentLinkCard {
    /// Drawn at scale 1: 1200 x 1200 px.
    static let side: CGFloat = 1200
    static let inset: CGFloat = 96
    static let markSide: CGFloat = 176
    static let labelSize: CGFloat = 64
    static let amountBottom: CGFloat = 84
    /// 1200 - 2 x 96.
    static let amountWidth: CGFloat = 1008
    static let numberSize: CGFloat = 340
    static let numberTracking: CGFloat = -4
    static let unitSize: CGFloat = 144
    static let unitGap: CGFloat = 32
    /// Smaller than this the amount is too small to read: round it.
    static let minimumScale: CGFloat = 0.4

    // MARK: - Amount text

    /// The full amount, every digit and no trailing zeros: "0.05",
    /// "12.3456789012".
    static func amountText(_ piconero: UInt64) -> String {
        format(EnvelopeRuntime.xmr(piconero), fractionDigits: 12)
    }

    /// The card's amount and the scale of its line (the number, the gap and
    /// "XMR" shrink together).
    struct Amount: Equatable {
        let text: String
        /// 1 at full size.
        let scale: CGFloat
    }

    /// The full amount, shrunk to fit. When that would take it below 40%,
    /// the amount rounded with "~": two decimals ("~12.35"), or two
    /// significant digits for a smaller amount ("~0.00012"), then whole
    /// coins. Never "XMR" alone: the last form shrinks as far as it must.
    /// `width` is the line's width at full size.
    static func amount(_ piconero: UInt64, width: (String) -> CGFloat = PaymentLinkCard.lineWidth) -> Amount {
        let value = EnvelopeRuntime.xmr(piconero)
        let full = amountText(piconero)
        var candidates = [full]
        for digits in [roundedFractionDigits(value), 0] {
            let rounded = format(value, fractionDigits: digits)
            guard rounded != full, rounded != "0" else { continue }
            let text = "~" + rounded
            if !candidates.contains(text) { candidates.append(text) }
        }
        for text in candidates {
            let scale = fitScale(width: width(text), into: amountWidth)
            if scale >= minimumScale { return Amount(text: text, scale: scale) }
        }
        let last = candidates[candidates.count - 1]
        return Amount(text: last, scale: fitScale(width: width(last), into: amountWidth))
    }

    /// The amount line at full size: the number, the gap and "XMR".
    static func lineWidth(_ text: String) -> CGFloat {
        textWidth(text, font: numberFont(size: numberSize), tracking: numberTracking)
            + unitGap
            + textWidth("XMR", font: roundedFont(size: unitSize, weight: .semibold), tracking: 0)
    }

    /// Two decimals, or more for an amount under 0.1: two significant digits.
    static func roundedFractionDigits(_ value: Decimal) -> Int {
        let tenth = Decimal(sign: .plus, exponent: -1, significand: 1)
        var scaled = value
        var leadingZeros = 0
        while scaled > 0, scaled < tenth, leadingZeros < 10 {
            scaled *= 10
            leadingZeros += 1
        }
        return max(2, leadingZeros + 2)
    }

    private static func format(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ","
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    private static func fitScale(width: CGFloat, into available: CGFloat) -> CGFloat {
        width > available ? available / width : 1
    }

    // MARK: - Fonts

    /// SF Pro Rounded, as `Font.system(size:weight:design: .rounded)`.
    static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    /// The amount's font: rounded bold with tabular digits (`monospacedDigit()`).
    static func numberFont(size: CGFloat) -> UIFont {
        let font = roundedFont(size: size, weight: .bold)
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func textWidth(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font, .kern: tracking]).width)
    }

    /// How far a SwiftUI text box reaches past a CSS box with line-height 1,
    /// at the top and at the bottom: half of (ascender + descender - size).
    static func boxOverhang(size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let font = roundedFont(size: size, weight: weight)
        return (font.ascender - font.descender - size) / 2
    }

    // MARK: - Rendering

    /// The card for `piconero`, 1200 x 1200 px.
    @MainActor
    static func image(amount piconero: UInt64) -> UIImage? {
        let renderer = ImageRenderer(content: PaymentLinkCardView(amount: amount(piconero)).environment(\.colorScheme, .light))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Views

/// 1200 x 1200: the coin top left, "Payment link" top right, the amount
/// bottom left.
struct PaymentLinkCardView: View {
    let amount: PaymentLinkCard.Amount

    var body: some View {
        let numberSize = PaymentLinkCard.numberSize * amount.scale
        ZStack(alignment: .topLeading) {
            PaymentLinkCardBackground()
            PaymentLinkCardMark(side: PaymentLinkCard.markSide)
                .padding(PaymentLinkCard.inset)
            Text("Payment link")
                .font(.system(size: PaymentLinkCard.labelSize, weight: .medium))
                .lineLimit(1)
                .frame(height: PaymentLinkCard.markSide)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding([.top, .trailing], PaymentLinkCard.inset)
            HStack(alignment: .firstTextBaseline, spacing: PaymentLinkCard.unitGap * amount.scale) {
                Text(verbatim: amount.text)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(PaymentLinkCard.numberTracking * amount.scale)
                Text(verbatim: "XMR")
                    .font(.system(size: PaymentLinkCard.unitSize * amount.scale, weight: .semibold, design: .rounded))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, PaymentLinkCard.inset)
            .padding(.bottom, PaymentLinkCard.amountBottom - PaymentLinkCard.boxOverhang(size: numberSize, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: PaymentLinkCard.side, height: PaymentLinkCard.side)
    }
}

/// Brand to brandPressed on the diagonal, with a faint white highlight at
/// the top.
private struct PaymentLinkCardBackground: View {
    var body: some View {
        LinearGradient(colors: [.brandToken, .brandPressed], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.12), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.4)
                )
            )
    }
}

private struct PaymentLinkCardMark: View {
    let side: CGFloat

    var body: some View {
        // Founder-approved exception to the logo rule (mark off orange): the one-color white coin on the orange card.
        Image("MoneroMarkWhite")
            .resizable()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}
