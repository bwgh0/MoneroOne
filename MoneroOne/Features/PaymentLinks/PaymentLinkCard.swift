import SwiftUI
import UIKit

/// The picture a shared payment link carries: the sealed envelope with the
/// amount in orange foil, one square for LPLinkMetadata.imageProvider (the
/// Messages bubble and the share sheet header). Drawn on the sender's phone
/// once per share; nothing loads the link. Fixed colors, so the picture
/// looks the same in light and dark. Always XMR, also in Fiat Mode. Sizes
/// are the mockup's pixels (link-card, final-share.html).
enum PaymentLinkCard {
    /// Drawn at scale 1: 1200 x 1200 px.
    static let side: CGFloat = 1200
    /// The envelope's place on the picture.
    static let envelopeOrigin = CGPoint(x: 100, y: 260)
    /// The foil line's top, on the envelope.
    static let foilTop: CGFloat = 452
    /// The widest the foil line may be, on the envelope's 1000.
    static let amountWidth: CGFloat = 820
    static let numberSize: CGFloat = 104
    static let numberTracking: CGFloat = 0
    static let unitSize: CGFloat = 104 * 0.46
    static let unitGap: CGFloat = 104 * 0.46 * 0.14
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

    /// The foil as the send step shows it: the note's amount (in Fiat Mode
    /// the fiat amount, without "XMR"), shrunk to fit, never under 40%.
    static func foil(_ text: String, showsUnit: Bool) -> Amount {
        let width = showsUnit
            ? lineWidth(text)
            : textWidth(text, font: numberFont(size: numberSize, weight: .semibold), tracking: numberTracking)
        return Amount(text: text, scale: max(minimumScale, fitScale(width: width, into: amountWidth)))
    }

    /// The amount line at full size: the number, the gap and "XMR".
    static func lineWidth(_ text: String) -> CGFloat {
        textWidth(text, font: numberFont(size: numberSize, weight: .semibold), tracking: numberTracking)
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

    /// The amount's font: rounded, with tabular digits (`monospacedDigit()`).
    static func numberFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = roundedFont(size: size, weight: weight)
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

/// 1200 x 1200: the sealed envelope on warm paper gray, the amount in
/// orange foil under the seal.
struct PaymentLinkCardView: View {
    let amount: PaymentLinkCard.Amount

    var body: some View {
        ZStack(alignment: .topLeading) {
            EllipticalGradient(
                stops: [
                    .init(color: EnvelopeArt.backdropLight, location: 0),
                    .init(color: EnvelopeArt.backdropMiddle, location: 0.62),
                    .init(color: EnvelopeArt.backdropDeep, location: 1),
                ],
                center: UnitPoint(x: 0.5, y: 0.4),
                startRadiusFraction: 0,
                endRadiusFraction: 0.78
            )
            ZStack(alignment: .topLeading) {
                EnvelopeShadow()
                EnvelopeFront { PaymentLinkCardFoil(amount: amount) }
            }
            .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
            .offset(x: PaymentLinkCard.envelopeOrigin.x, y: PaymentLinkCard.envelopeOrigin.y)
        }
        .frame(width: PaymentLinkCard.side, height: PaymentLinkCard.side, alignment: .topLeading)
    }
}

/// The amount pressed into the pocket in orange foil, centered on the
/// envelope's 1000 units, its line's top at 452.
struct PaymentLinkCardFoil: View {
    let amount: PaymentLinkCard.Amount
    /// "XMR" after the number; a fiat amount has none.
    var showsUnit = true

    var body: some View {
        let size = PaymentLinkCard.numberSize * amount.scale
        LinearGradient(
            stops: [
                .init(color: EnvelopeArt.foilDeep, location: 0),
                .init(color: EnvelopeArt.waxLight, location: 0.36),
                .init(color: .brandToken, location: 0.66),
                .init(color: EnvelopeArt.foilEnd, location: 0.98),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: Envelope.width, height: size * 1.4)
        .mask(line(size: size))
        .shadow(color: .black.opacity(0.75), radius: 0, x: 0, y: -1.4)
        .shadow(color: .white.opacity(0.09), radius: 0, x: 0, y: 1.1)
        .offset(y: PaymentLinkCard.foilTop - PaymentLinkCard.boxOverhang(size: size, weight: .semibold))
        .accessibilityHidden(true)
    }

    private func line(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaymentLinkCard.unitGap * amount.scale) {
            Text(verbatim: amount.text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if showsUnit {
                Text(verbatim: "XMR")
                    .font(.system(size: PaymentLinkCard.unitSize * amount.scale, weight: .semibold, design: .rounded))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: Envelope.width, height: size * 1.4, alignment: .top)
    }
}
