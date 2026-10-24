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
    var weight: UIFont.Weight = .regular
    var color: UIColor = .secondaryLabel
    var alignment: NSTextAlignment = .natural
    var selectable = false
    /// `.byWordWrapping` breaks at spaces and zero-width spaces first, and
    /// between characters only inside a part longer than the line.
    var lineBreakMode: NSLineBreakMode = .byCharWrapping

    init(
        _ text: String,
        style: UIFont.TextStyle = .caption1,
        monospaced: Bool = true,
        weight: UIFont.Weight = .regular,
        color: UIColor = .secondaryLabel,
        alignment: NSTextAlignment = .natural,
        selectable: Bool = false,
        lineBreakMode: NSLineBreakMode = .byCharWrapping
    ) {
        self.text = text
        self.style = style
        self.monospaced = monospaced
        self.weight = weight
        self.color = color
        self.alignment = alignment
        self.selectable = selectable
        self.lineBreakMode = lineBreakMode
    }

    var body: some View {
        CharacterWrappedText(
            text: text,
            style: style,
            monospaced: monospaced,
            weight: weight,
            color: color,
            alignment: alignment,
            selectable: selectable,
            lineBreakMode: lineBreakMode
        )
        // VoiceOver reads it as the Text it replaces.
        .accessibilityRepresentation { Text(verbatim: text) }
    }
}

private struct CharacterWrappedText: UIViewRepresentable {
    let text: String
    let style: UIFont.TextStyle
    let monospaced: Bool
    let weight: UIFont.Weight
    let color: UIColor
    let alignment: NSTextAlignment
    let selectable: Bool
    let lineBreakMode: NSLineBreakMode

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isSelectable = selectable
        // Not selectable: taps reach what it sits in (a button, a link).
        view.isUserInteractionEnabled = selectable
        let paragraph = NSMutableParagraphStyle()
        view.textContainer.lineBreakMode = lineBreakMode
        paragraph.lineBreakMode = lineBreakMode
        paragraph.hyphenationFactor = 0
        paragraph.alignment = alignment
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
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
        codeFont(style: style, monospaced: monospaced, weight: weight)
    }
}

/// The font of the SwiftUI text style it stands in for, scaled with
/// Dynamic Type.
private func codeFont(style: UIFont.TextStyle, monospaced: Bool, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.preferredFont(
        forTextStyle: style,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    let face = monospaced
        ? UIFont.monospacedSystemFont(ofSize: base, weight: weight)
        : UIFont.systemFont(ofSize: base, weight: weight)
    return UIFontMetrics(forTextStyle: style).scaledFont(for: face)
}

/// An editable address field. A vertical `TextField` breaks a long address
/// with a hyphen ("…NcpTKr-"), like `Text`. This one breaks between any two
/// characters and never adds a hyphen. It types, pastes and grows like
/// `TextField("", text:, axis: .vertical)`, with autocorrect and
/// capitalization off.
struct CodeTextField: UIViewRepresentable {
    @Binding var text: String
    var style: UIFont.TextStyle = .callout
    var monospaced = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = .brand
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        let font = codeFont(style: style, monospaced: monospaced, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        view.typingAttributes = attributes
        // Typing reaches here with the same text: leave it, so the caret,
        // undo and a marked (IME) text stay. A new value (a scan, a paste
        // from Send) or a new font (an address becoming a name) is set again.
        let textChanged = view.text != text
        let shown = view.textStorage.length > 0
            ? view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            : font
        let fontChanged = shown?.fontName != font.fontName || shown?.pointSize != font.pointSize
        guard textChanged || (fontChanged && view.markedTextRange == nil) else { return }
        let selection = view.selectedRange
        view.attributedText = NSAttributedString(string: text, attributes: attributes)
        if !textChanged { view.selectedRange = selection }
    }

    /// Takes the offered width, like `TextField`, and grows down.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
