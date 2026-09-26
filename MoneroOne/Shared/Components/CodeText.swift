import SwiftUI
import UIKit

/// An address, hash or key. SwiftUI's `Text` breaks a long run of letters
/// with a hyphen ("…EPAvk-"), which reads like part of the address. This
/// breaks between any two characters and never adds a hyphen. With
/// `selectable`, a long press selects it and Copy copies exactly `text`.
struct CodeText: View {
    let text: String
    var style: UIFont.TextStyle = .caption1
    var monospaced = true
    var color: UIColor = .secondaryLabel
    var alignment: NSTextAlignment = .natural
    var selectable = false
    /// Every other group of four characters in this color, so an address
    /// is easy to compare by eye. Color only: the text stays one unbroken
    /// string, so what Copy takes equals what is shown.
    var groupTint: UIColor?

    init(
        _ text: String,
        style: UIFont.TextStyle = .caption1,
        monospaced: Bool = true,
        color: UIColor = .secondaryLabel,
        alignment: NSTextAlignment = .natural,
        selectable: Bool = false,
        groupTint: UIColor? = nil
    ) {
        self.text = text
        self.style = style
        self.monospaced = monospaced
        self.color = color
        self.alignment = alignment
        self.selectable = selectable
        self.groupTint = groupTint
    }

    var body: some View {
        CharacterWrappedText(
            text: text,
            style: style,
            monospaced: monospaced,
            color: color,
            alignment: alignment,
            selectable: selectable,
            groupTint: groupTint
        )
        // VoiceOver reads it as the Text it replaces.
        .accessibilityRepresentation { Text(verbatim: text) }
    }
}

private struct CharacterWrappedText: UIViewRepresentable {
    let text: String
    let style: UIFont.TextStyle
    let monospaced: Bool
    let color: UIColor
    let alignment: NSTextAlignment
    let selectable: Bool
    let groupTint: UIColor?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isSelectable = selectable
        // Not selectable: taps reach what it sits in (a button, a link).
        view.isUserInteractionEnabled = selectable
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        paragraph.alignment = alignment
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        if let groupTint {
            let length = (text as NSString).length
            var start = 4
            while start < length {
                attributed.addAttribute(.foregroundColor, value: groupTint, range: NSRange(location: start, length: min(4, length - start)))
                start += 8
            }
        }
        view.attributedText = attributed
    }

    /// Hugs the text on one line like `Text`, else takes the offered width
    /// and grows down.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let oneLine = uiView.sizeThatFits(unbounded)
        guard let width = proposal.width, width.isFinite, oneLine.width > width else {
            return oneLine
        }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    /// The font of the `Text` it stands in for, `.system(.caption, design:
    /// .monospaced)` by default, scaled with Dynamic Type.
    private var font: UIFont {
        let base = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let face = monospaced
            ? UIFont.monospacedSystemFont(ofSize: base, weight: .regular)
            : UIFont.systemFont(ofSize: base)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: face)
    }
}
