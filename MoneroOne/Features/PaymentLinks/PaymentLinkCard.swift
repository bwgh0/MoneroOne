import SwiftUI
import UIKit

/// The picture a shared payment link carries, the "orange pass": a wide
/// card for the Messages bubble (LPLinkMetadata.imageProvider) and a square
/// for the share sheet header (iconProvider). Drawn on the sender's phone
/// once per share; nothing loads the link. Fixed colors, so the pictures
/// look the same in light and dark. Sizes are the spec's pixels
/// (MoneroOne-Link-Card-v2.html, Orange pass).
enum PaymentLinkCard {
    /// The wide card, drawn at scale 1: 1200 x 630 px.
    static let wideSize = CGSize(width: 1200, height: 630)
    /// The square: 180 units, 60 pt drawn at 3x.
    static let squareSide: CGFloat = 180
    /// The square is 60 pt in the share sheet header.
    static let squarePoints: CGFloat = 60

    static let wideInset: CGFloat = 72
    static let wideMark: CGFloat = 120
    static let wideAmountBottom: CGFloat = 56
    /// 1200 - 2 x 72.
    static let wideAmountWidth: CGFloat = 1056
    static let wideNumberSize: CGFloat = 232
    static let wideNumberTracking: CGFloat = -3
    static let wideUnitSize: CGFloat = 100
    static let wideGap: CGFloat = 24
    static let wideLabelSize: CGFloat = 48

    static let squareInset: CGFloat = 18
    static let squareMark: CGFloat = 48
    static let squareAmountBottom: CGFloat = 16
    /// 180 - 2 x 18.
    static let squareAmountWidth: CGFloat = 144
    static let squareNumberSize: CGFloat = 56
    static let squareNumberTracking: CGFloat = -1
    static let squareUnitSize: CGFloat = 26
    static let squareUnitGap: CGFloat = 4
    /// Smaller than this the amount is too small to read: round it.
    static let squareMinimumScale: CGFloat = 0.4

    // MARK: - Amount text

    /// The full amount, every digit and no trailing zeros: "0.05",
    /// "12.3456789012".
    static func amountText(_ piconero: UInt64) -> String {
        format(EnvelopeRuntime.xmr(piconero), fractionDigits: 12)
    }

    /// The square's amount and the scale of its number.
    struct SquareAmount: Equatable {
        let text: String
        /// 1 at full size.
        let scale: CGFloat
    }

    /// The full amount, shrunk to fit. When that would take it below 40%,
    /// the amount rounded with "~": two decimals ("~12.35"), or two
    /// significant digits for a smaller amount ("~0.00012"), then whole
    /// coins. Never "XMR" alone: the last form shrinks as far as it must.
    static func squareAmount(_ piconero: UInt64, width: (String) -> CGFloat = PaymentLinkCard.squareNumberWidth) -> SquareAmount {
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
            let scale = fitScale(width: width(text), into: squareAmountWidth)
            if scale >= squareMinimumScale { return SquareAmount(text: text, scale: scale) }
        }
        let last = candidates[candidates.count - 1]
        return SquareAmount(text: last, scale: fitScale(width: width(last), into: squareAmountWidth))
    }

    /// The wide card's amount and "XMR" shrink together to fit its width.
    static func wideScale(for amount: String) -> CGFloat {
        let width = textWidth(amount, font: numberFont(size: wideNumberSize), tracking: wideNumberTracking)
            + wideGap
            + textWidth("XMR", font: roundedFont(size: wideUnitSize, weight: .semibold), tracking: 0)
        return fitScale(width: width, into: wideAmountWidth)
    }

    static func squareNumberWidth(_ text: String) -> CGFloat {
        textWidth(text, font: numberFont(size: squareNumberSize), tracking: squareNumberTracking)
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

    /// The wide card (1200 x 630 px) and the square (60 pt at the
    /// device's scale) for `piconero`.
    @MainActor
    static func images(amount piconero: UInt64, displayScale: CGFloat) -> (wide: UIImage?, square: UIImage?) {
        let wide = render(PaymentLinkWideCard(amount: amountText(piconero)), scale: 1)
        let square = render(
            PaymentLinkSquareCard(amount: squareAmount(piconero)),
            scale: squarePoints * max(displayScale, 1) / squareSide
        )
        return (wide, square)
    }

    @MainActor
    private static func render(_ view: some View, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Views

/// 1200 x 630: the coin top left, "Payment link" top right, the amount
/// bottom left.
struct PaymentLinkWideCard: View {
    let amount: String

    var body: some View {
        let scale = PaymentLinkCard.wideScale(for: amount)
        let numberSize = PaymentLinkCard.wideNumberSize * scale
        ZStack(alignment: .topLeading) {
            PaymentLinkCardBackground()
            PaymentLinkCardMark(side: PaymentLinkCard.wideMark)
                .padding(PaymentLinkCard.wideInset)
            Text("Payment link")
                .font(.system(size: PaymentLinkCard.wideLabelSize, weight: .medium))
                .lineLimit(1)
                .frame(height: PaymentLinkCard.wideMark)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding([.top, .trailing], PaymentLinkCard.wideInset)
            HStack(alignment: .firstTextBaseline, spacing: PaymentLinkCard.wideGap * scale) {
                Text(verbatim: amount)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(PaymentLinkCard.wideNumberTracking * scale)
                Text(verbatim: "XMR")
                    .font(.system(size: PaymentLinkCard.wideUnitSize * scale, weight: .semibold, design: .rounded))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, PaymentLinkCard.wideInset)
            .padding(.bottom, PaymentLinkCard.wideAmountBottom - PaymentLinkCard.boxOverhang(size: numberSize, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: PaymentLinkCard.wideSize.width, height: PaymentLinkCard.wideSize.height)
    }
}

/// 180 x 180: the coin top left, the amount bottom left with "XMR" under it.
struct PaymentLinkSquareCard: View {
    let amount: PaymentLinkCard.SquareAmount

    var body: some View {
        let numberSize = PaymentLinkCard.squareNumberSize * amount.scale
        let numberOverhang = PaymentLinkCard.boxOverhang(size: numberSize, weight: .bold)
        let unitOverhang = PaymentLinkCard.boxOverhang(size: PaymentLinkCard.squareUnitSize, weight: .semibold)
        ZStack(alignment: .topLeading) {
            PaymentLinkCardBackground()
            PaymentLinkCardMark(side: PaymentLinkCard.squareMark)
                .padding(PaymentLinkCard.squareInset)
            VStack(alignment: .leading, spacing: PaymentLinkCard.squareUnitGap - numberOverhang - unitOverhang) {
                Text(verbatim: amount.text)
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(PaymentLinkCard.squareNumberTracking * amount.scale)
                Text(verbatim: "XMR")
                    .font(.system(size: PaymentLinkCard.squareUnitSize, weight: .semibold, design: .rounded))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, PaymentLinkCard.squareInset)
            .padding(.bottom, PaymentLinkCard.squareAmountBottom - unitOverhang)
        }
        .foregroundStyle(.white)
        .frame(width: PaymentLinkCard.squareSide, height: PaymentLinkCard.squareSide)
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
