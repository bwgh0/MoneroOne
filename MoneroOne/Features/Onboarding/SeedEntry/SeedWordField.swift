import SwiftUI
import UIKit

/// One seed word cell's text field. UIKit, because SwiftUI's `TextField`
/// cannot turn off every typing aid (spec 2.6), report backspace in an empty
/// field, or take over paste.
struct SeedWordField: UIViewRepresentable {
    let index: Int
    let text: String
    let isInvalid: Bool
    let isLast: Bool
    let model: SeedEntryModel

    func makeUIView(context: Context) -> SeedWordTextField {
        let field = SeedWordTextField()
        field.delegate = context.coordinator
        field.pasteDelegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.onDeleteBackwardInEmptyField = { [weak coordinator = context.coordinator] in
            coordinator?.deleteBackwardInEmptyField()
        }
        field.onTab = { [weak coordinator = context.coordinator] in
            coordinator?.tab()
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: SeedWordTextField, context: Context) {
        context.coordinator.parent = self
        model.keyboard.register(field, at: index)
        field.isInvalid = isInvalid
        field.accessibilityLabel = String(localized: "Word \(index + 1)")
        field.accessibilityIdentifier = "restore.seedWord.\(index + 1)"
        if field.isFirstResponder {
            // Changing the editing field's text or keyboard makes UIKit run
            // queued key events into the delegate at once. Inside a SwiftUI
            // update that re-enters the view graph (it hung on fast typing),
            // so sync the editing field on the next turn of the run loop.
            if (field.text ?? "") != text || field.returnKeyType != returnKeyType {
                let coordinator = context.coordinator
                DispatchQueue.main.async { [weak field] in
                    guard let field else { return }
                    coordinator.syncEditingField(field)
                }
            }
        } else {
            if (field.text ?? "") != text {
                field.text = text
            }
            field.returnKeyType = returnKeyType
        }
    }

    private var returnKeyType: UIReturnKeyType { isLast ? .done : .next }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SeedWordTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: uiView.intrinsicContentSize.height)
    }

    static func dismantleUIView(_ field: SeedWordTextField, coordinator: Coordinator) {
        coordinator.parent.model.keyboard.unregister(field)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate, UITextPasteDelegate {
        var parent: SeedWordField

        init(parent: SeedWordField) {
            self.parent = parent
        }

        private var model: SeedEntryModel { parent.model }
        private var index: Int { parent.index }

        /// Brings the editing field in line with the model (Clear, or a
        /// count change that makes it the last cell). Never during an IME
        /// composition.
        func syncEditingField(_ field: SeedWordTextField) {
            guard field.markedTextRange == nil, model.words.indices.contains(index) else { return }
            let text = model.words[index]
            if (field.text ?? "") != text {
                field.text = text
            }
            if field.returnKeyType != parent.returnKeyType {
                field.returnKeyType = parent.returnKeyType
                if field.isFirstResponder {
                    field.reloadInputViews()
                }
            }
        }

        /// The suggestion bar rides on the editing field only. A field that
        /// kept it after a swipe-down dismissal left the keyboard layout
        /// guide 48pt tall (the bar) on iOS 27, so Continue sat 14pt high.
        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
            textField.inputAccessoryView = model.keyboard.suggestionBar
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            model.didBeginEditing(index)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            textField.inputAccessoryView = nil
            model.didEndEditing(index)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            model.commit(index, advance: true)
            return false
        }

        func tab() {
            model.commit(index, advance: true)
        }

        func deleteBackwardInEmptyField() {
            model.deleteBackwardInEmptyCell(index)
        }

        /// Separators commit the word (space, comma, return, tab). Text with
        /// separators that is not a paste (dictation, a keyboard extension)
        /// splits like a paste but leaves the clipboard alone.
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard textField.markedTextRange == nil, !string.isEmpty,
                  string.contains(where: SeedEntryModel.isSeparator) else { return true }
            let current = textField.text ?? ""
            if string.allSatisfy(SeedEntryModel.isSeparator) {
                if !SeedPhraseValidator.normalize(current).isEmpty {
                    model.commit(index, advance: true)
                }
                return false
            }
            let tokens = SeedPasteParser.parse(string)
            if tokens.count >= 2 {
                model.insert(tokens, at: index)
            } else if let token = tokens.first, let swiftRange = Range(range, in: current) {
                let updated = current.replacingCharacters(in: swiftRange, with: token)
                textField.text = updated
                model.setText(updated, at: index)
                model.commit(index, advance: true)
            }
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            // Leave an IME composition alone; its text arrives on commit.
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            // Separators that bypassed shouldChangeCharactersIn (an IME commit).
            if text.contains(where: SeedEntryModel.isSeparator) {
                let tokens = SeedPasteParser.parse(text)
                if tokens.count >= 2 {
                    field.text = ""
                    model.setText("", at: index)
                    model.insert(tokens, at: index)
                } else {
                    let word = tokens.first ?? ""
                    field.text = word
                    model.setText(word, at: index)
                    if !word.isEmpty {
                        model.commit(index, advance: true)
                    }
                }
                return
            }
            // Locale-independent lowercase (Swift's `lowercased()` ignores the
            // current locale, so Turkish I stays i).
            let lower = text.lowercased()
            if lower != text {
                let fromEnd = field.selectedTextRange.map { field.offset(from: $0.end, to: field.endOfDocument) } ?? 0
                field.text = lower
                if let caret = field.position(from: field.endOfDocument, offset: -fromEnd) {
                    field.selectedTextRange = field.textRange(from: caret, to: caret)
                }
            }
            model.setText(lower, at: index)
        }

        // MARK: UITextPasteDelegate

        /// Pastes from the edit menu, the keyboard and Command-V. Two or more
        /// words fill the grid and clear the clipboard; one word goes into
        /// the cell, cleaned like a paste.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString,
            to textRange: UITextRange
        ) -> UITextRange {
            guard let field = textPasteConfigurationSupporting as? UITextField else { return textRange }
            let tokens = SeedPasteParser.parse(attributedString.string)
            if tokens.count >= 2 {
                let index = self.index
                let model = self.model
                DispatchQueue.main.async {
                    model.insert(tokens, at: index)
                    // Do not read the pasteboard to compare: reading shows
                    // the paste prompt.
                    UIPasteboard.general.items = []
                }
                return field.textRange(from: field.beginningOfDocument, to: field.beginningOfDocument) ?? textRange
            }
            let word = tokens.first ?? ""
            let start = field.offset(from: field.beginningOfDocument, to: textRange.start)
            field.replace(textRange, withText: word)
            editingChanged(field)
            let end = field.position(from: field.beginningOfDocument, offset: start + (word as NSString).length)
                ?? field.endOfDocument
            return field.textRange(from: end, to: end) ?? textRange
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            shouldAnimatePasteOf attributedString: NSAttributedString,
            to textRange: UITextRange
        ) -> Bool {
            false
        }
    }
}

/// The text field behind a seed cell: every typing aid off, monospaced
/// Dynamic Type text, backspace and tab reported to the grid.
final class SeedWordTextField: UITextField {
    var onDeleteBackwardInEmptyField: (() -> Void)?
    var onTab: (() -> Void)?

    var isInvalid = false {
        didSet {
            guard isInvalid != oldValue else { return }
            textColor = isInvalid ? .systemRed : .label
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        if #available(iOS 18.0, *) {
            writingToolsBehavior = .none
        }
        keyboardType = .default
        textContentType = nil
        clearButtonMode = .never
        borderStyle = .none
        backgroundColor = .clear
        textColor = .label
        tintColor = .brand
        font = Self.scaledFont(for: traitCollection)
        adjustsFontForContentSizeCategory = true
        adjustsFontSizeToFitWidth = true
        minimumFontSize = 11
        // A text size change while the screen is open left a field that had
        // shrunk its word to fit with the old size and height; set the font
        // again and let the grid re-measure.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (field: SeedWordTextField, _: UITraitCollection) in
            field.font = Self.scaledFont(for: field.traitCollection)
            field.invalidateIntrinsicContentSize()
            field.setNeedsLayout()
        }
        // No shortcut bar on iPad and Duo.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    private static func scaledFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular), compatibleWith: traits)
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty, markedTextRange == nil {
            onDeleteBackwardInEmptyField?()
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabPressed))
        tab.wantsPriorityOverSystemBehavior = true
        return [tab]
    }

    @objc private func tabPressed() {
        onTab?()
    }

    override var accessibilityValue: String? {
        get {
            let word = text ?? ""
            if word.isEmpty {
                return String(localized: "Empty")
            }
            return isInvalid ? "\(word), \(String(localized: "Not in the word list"))" : word
        }
        set { super.accessibilityValue = newValue }
    }
}

/// The UIKit side of the grid: the visible text fields (weakly held) for
/// focus moves, and the suggestion bar shared by every cell.
final class SeedKeyboardController {
    private final class WeakField {
        weak var field: SeedWordTextField?
        init(_ field: SeedWordTextField) { self.field = field }
    }

    private var fields: [Int: WeakField] = [:]
    let suggestionBar = SeedSuggestionBar()

    init() {
        suggestionBar.onHideKeyboard = { [weak self] in self?.dismiss() }
    }

    var onSuggestion: ((String) -> Void)? {
        get { suggestionBar.onSelect }
        set { suggestionBar.onSelect = newValue }
    }

    func register(_ field: SeedWordTextField, at index: Int) {
        if fields[index]?.field !== field {
            fields[index] = WeakField(field)
        }
    }

    func unregister(_ field: SeedWordTextField) {
        fields = fields.filter { $0.value.field != nil && $0.value.field !== field }
    }

    /// Focuses a cell with the caret at the end.
    func focus(_ index: Int) {
        guard let field = fields[index]?.field else { return }
        field.becomeFirstResponder()
        let end = field.endOfDocument
        field.selectedTextRange = field.textRange(from: end, to: end)
    }

    func dismiss() {
        for box in fields.values where box.field?.isFirstResponder == true {
            box.field?.resignFirstResponder()
        }
    }

    /// Empties every visible field now. SwiftUI syncs the editing field a
    /// run loop turn later and never during an IME composition, so a clear
    /// that waited for it could leave old text there. A composition ends
    /// first and reports its text, so call this before the model clears.
    func clearFields() {
        for box in fields.values {
            guard let field = box.field else { continue }
            if field.markedTextRange != nil {
                field.unmarkText()
            }
            if !(field.text ?? "").isEmpty {
                field.text = ""
            }
        }
    }

    func showSuggestions(_ words: [String]) {
        suggestionBar.show(words)
    }
}

/// Up to three list words above the keyboard, and a trailing button that
/// hides the keyboard. It stays in place when there is nothing to suggest,
/// so the keyboard height does not jump while typing.
final class SeedSuggestionBar: UIToolbar {
    var onSelect: ((String) -> Void)?
    var onHideKeyboard: (() -> Void)?
    private var shown: [String] = []

    private lazy var hideKeyboardItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            primaryAction: UIAction { [weak self] _ in self?.onHideKeyboard?() }
        )
        item.accessibilityLabel = String(localized: "Hide keyboard")
        item.accessibilityIdentifier = "restore.hideKeyboard"
        return item
    }()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        sizeToFit()
        tintColor = .label
        accessibilityIdentifier = "restore.seedSuggestions"
        layOut([])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func show(_ words: [String]) {
        guard words != shown else { return }
        shown = words
        layOut(words)
    }

    /// The words spread over the bar (one word centered), then the hide
    /// button at the trailing edge.
    private func layOut(_ words: [String]) {
        var items: [UIBarButtonItem] = []
        for (i, word) in words.enumerated() {
            if i > 0 || words.count == 1 {
                items.append(.flexibleSpace())
            }
            let item = UIBarButtonItem(
                title: word,
                primaryAction: UIAction(title: word) { [weak self] _ in self?.onSelect?(word) }
            )
            item.accessibilityLabel = word
            item.accessibilityIdentifier = "restore.seedSuggestion.\(i + 1)"
            items.append(item)
        }
        items.append(.flexibleSpace())
        items.append(hideKeyboardItem)
        setItems(items, animated: false)
    }
}
