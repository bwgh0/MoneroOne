import SwiftUI
import UIKit
import Observation

/// The line under the word grid.
struct SeedEntryStatus: Equatable {
    enum Tone: Equatable {
        case neutral
        case error
        case success
    }

    let text: String
    let tone: Tone
    /// Second line (Polyseed: "Wallet created around …").
    var detail: String?
}

/// Where the restore screen scrolls after an action. The serial lets the
/// same target repeat.
struct SeedEntryScrollRequest: Equatable {
    enum Target: Equatable {
        /// The status line under the grid, when it has news: a full paste, a
        /// paste that fits nowhere, the last word committed, an error from
        /// Continue.
        case status
        /// The top of the step (word count, Paste, word 1), after Clear.
        case top
    }

    let target: Target
    let serial: Int
}

/// The seed words typed on the restore screen. Lives only in memory, owned by
/// `RestoreWalletView` (`@State`); `reset()` clears it when the flow ends.
///
/// Rules (spec 2.2 to 2.4): commit (space, return, comma, tab, a suggestion
/// or focus loss) turns a typed prefix into the list word; a cell shows the
/// invalid state only once it is settled (committed or not focused); a new
/// word count starts over with empty cells.
@Observable
final class SeedEntryModel {
    static let cellCount = 25

    private(set) var format: SeedFormat = .legacy
    private(set) var words = [String](repeating: "", count: cellCount)
    private(set) var committed = [Bool](repeating: false, count: cellCount)
    private(set) var focusedIndex: Int?
    /// A paste whose word count fits nowhere. The next edit clears it.
    private(set) var showsCountError = false
    /// An error from the step's Continue action (the duplicate-wallet check).
    /// The next edit clears it.
    private(set) var externalError: String?
    /// Set when an action should move the screen: see `SeedEntryScrollRequest`.
    private(set) var scrollRequest: SeedEntryScrollRequest?

    private(set) var outcome: SeedPhraseValidator.Outcome = .incomplete
    private(set) var invalidCells: Set<Int> = []
    private(set) var status = SeedEntryStatus(text: "", tone: .neutral)

    /// The UIKit side: text fields and the suggestion bar.
    @ObservationIgnored let keyboard = SeedKeyboardController()

    init() {
        keyboard.onSuggestion = { [weak self] word in self?.acceptSuggestion(word) }
        refresh()
    }

    var wordCount: Int { format.wordCount }

    /// The canonical list words when the phrase is valid.
    var validWords: [String]? {
        if case .valid(let phrase) = outcome { return phrase.words }
        return nil
    }

    var isValid: Bool { validWords != nil }

    var hasText: Bool {
        words.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c == "," || c == "\u{3001}" || c == "\u{FF0C}"
    }

    // MARK: - Editing

    func showError(_ message: String?) {
        guard message != externalError else { return }
        externalError = message
        refresh()
        if message != nil {
            requestScroll(.status)
        }
    }

    /// The word count control (spec 2.2). Another count clears every word,
    /// the invalid marks, the status line and the suggestions; the selected
    /// count does nothing. Focus goes to word 1 when a cell had it, else the
    /// keyboard stays down. A paste that fits another count does not come
    /// here: `insert` sets the format and keeps the pasted words.
    func setFormat(_ newFormat: SeedFormat) {
        guard newFormat != format else { return }
        // Move focus before the clear: the cell that loses it reports any
        // IME composition now, not into the empty grid.
        if focusedIndex != nil {
            keyboard.focus(0)
        }
        format = newFormat
        dropWords()
    }

    /// The text of a cell changed by typing.
    func setText(_ text: String, at index: Int) {
        guard words.indices.contains(index), words[index] != text else { return }
        words[index] = text
        committed[index] = false
        clearTransientErrors()
        refresh()
    }

    /// Space, comma, tab or return in a cell.
    func commit(_ index: Int, advance: Bool) {
        let wasDone = isDone(at: index)
        settle(index)
        refresh()
        if advance {
            self.advance(from: index, wasDone: wasDone)
        }
    }

    func didBeginEditing(_ index: Int) {
        focusedIndex = index
        refresh()
    }

    func didEndEditing(_ index: Int) {
        if focusedIndex == index {
            focusedIndex = nil
        }
        settle(index)
        refresh()
    }

    func deleteBackwardInEmptyCell(_ index: Int) {
        guard index > 0 else { return }
        keyboard.focus(index - 1)
    }

    func acceptSuggestion(_ word: String) {
        guard let index = focusedIndex else { return }
        let wasDone = isDone(at: index)
        words[index] = word
        committed[index] = true
        clearTransientErrors()
        refresh()
        advance(from: index, wasDone: wasDone)
    }

    /// Words from the Paste button (`index` nil) or pasted into a cell.
    /// A supported count replaces everything; otherwise the words fill the
    /// grid from the cell they were pasted into, when they fit.
    func insert(_ tokens: [String], at index: Int?) {
        externalError = nil
        if let pasted = SeedFormat(wordCount: tokens.count) {
            format = pasted
            let canonical = tokens.map { SeedPhraseValidator.canonicalOnCommit($0, format: pasted, committed: tokens) }
            words = canonical + [String](repeating: "", count: Self.cellCount - canonical.count)
            committed = (0..<Self.cellCount).map { $0 < canonical.count }
            showsCountError = false
            keyboard.dismiss()
            requestScroll(.status)
        } else if let index, !tokens.isEmpty, index + tokens.count <= format.wordCount {
            let context = settledWords(excluding: nil) + tokens
            for (offset, token) in tokens.enumerated() {
                words[index + offset] = SeedPhraseValidator.canonicalOnCommit(token, format: format, committed: context)
                committed[index + offset] = true
            }
            showsCountError = false
            refresh()
            let next = index + tokens.count
            if next < format.wordCount, !isValid {
                keyboard.focus(next)
            } else {
                keyboard.dismiss()
                requestScroll(.status)
            }
        } else {
            showsCountError = true
            requestScroll(.status)
        }
        refresh()
    }

    /// The Paste button. Clears the clipboard after a multi-word paste
    /// (writing to the pasteboard shows no prompt; never read it back).
    func paste(_ text: String) {
        let tokens = SeedPasteParser.parse(text)
        insert(tokens, at: nil)
        if tokens.count >= 2 {
            UIPasteboard.general.items = []
        }
    }

    /// The Clear button: every cell. The screen goes back to the top, to
    /// word 1 and Paste.
    func clearAll() {
        dropWords()
        requestScroll(.top)
    }

    /// The flow ended: drop every word.
    func reset() {
        keyboard.dismiss()
        format = .legacy
        focusedIndex = nil
        dropWords()
    }

    // MARK: - Private

    /// Every cell, the UIKit fields first: an IME composition that ends there
    /// reaches the model before the words go, and no field keeps old text.
    private func dropWords() {
        keyboard.clearFields()
        words = [String](repeating: "", count: Self.cellCount)
        committed = [Bool](repeating: false, count: Self.cellCount)
        showsCountError = false
        externalError = nil
        refresh()
    }

    private func requestScroll(_ target: SeedEntryScrollRequest.Target) {
        scrollRequest = SeedEntryScrollRequest(target: target, serial: (scrollRequest?.serial ?? 0) + 1)
    }

    private func clearTransientErrors() {
        showsCountError = false
        externalError = nil
    }

    /// After a commit: the next cell, or, on the last cell or when the commit
    /// made the phrase valid, close the keyboard and show the status line
    /// and Continue (spec 2.1 item 7). Return through an already valid,
    /// committed phrase still walks from cell to cell.
    private func advance(from index: Int, wasDone: Bool) {
        let next = index + 1
        if next < format.wordCount, wasDone || !isValid {
            keyboard.focus(next)
        } else {
            keyboard.dismiss()
            requestScroll(.status)
        }
    }

    /// The phrase is valid and the cell was already committed: a commit
    /// there changes nothing.
    private func isDone(at index: Int) -> Bool {
        isValid && committed.indices.contains(index) && committed[index]
    }

    /// Commit: the list word when the text stands for exactly one.
    private func settle(_ index: Int) {
        guard words.indices.contains(index) else { return }
        let normalized = SeedPhraseValidator.normalize(words[index])
        guard !normalized.isEmpty else {
            words[index] = ""
            committed[index] = false
            return
        }
        words[index] = SeedPhraseValidator.canonicalOnCommit(
            normalized, format: format, committed: settledWords(excluding: index)
        )
        committed[index] = true
    }

    private func isSettled(_ index: Int) -> Bool {
        committed[index] || focusedIndex != index
    }

    /// Normalized text of the visible, settled, non-empty cells.
    private func settledWords(excluding excluded: Int?) -> [String] {
        (0..<format.wordCount).compactMap { i in
            guard i != excluded, isSettled(i) else { return nil }
            let word = SeedPhraseValidator.normalize(words[i])
            return word.isEmpty ? nil : word
        }
    }

    private func refresh() {
        let count = format.wordCount
        let visible = Array(words.prefix(count))
        let normalized = visible.map(SeedPhraseValidator.normalize)
        let language = SeedPhraseValidator.activeLanguage(settledWords(excluding: nil), format: format)

        var invalid = Set<Int>()
        var filled = 0
        for i in 0..<count where !normalized[i].isEmpty {
            let known = SeedPhraseValidator.resolve(normalized[i], format: format, language: language) != nil
            if isSettled(i) {
                filled += 1
                if !known {
                    invalid.insert(i)
                }
            } else if known {
                // A word still being typed counts once it resolves.
                filled += 1
            }
        }
        invalidCells = invalid
        outcome = SeedPhraseValidator.validate(visible, format: format)
        status = makeStatus(filled: filled, count: count)
        updateSuggestions()
    }

    private func makeStatus(filled: Int, count: Int) -> SeedEntryStatus {
        if showsCountError {
            return SeedEntryStatus(text: String(localized: "Please enter 16, 24, or 25 words"), tone: .error)
        }
        if let externalError {
            return SeedEntryStatus(text: externalError, tone: .error)
        }
        if !invalidCells.isEmpty {
            return Self.checkWordsStatus(invalidCells.sorted())
        }
        if filled < count {
            return SeedEntryStatus(text: Self.partialText(filled, count), tone: .neutral)
        }
        switch outcome {
        case .valid(let phrase):
            let detail = phrase.birthday.map {
                String(localized: "Wallet created around \($0.formatted(.dateTime.month(.wide).year()))")
            }
            return SeedEntryStatus(text: String(localized: "Valid seed phrase"), tone: .success, detail: detail)
        case .passphrase:
            return SeedEntryStatus(
                text: String(localized: "This Polyseed uses a passphrase. Monero One does not support Polyseed passphrases yet."),
                tone: .error
            )
        case .invalid:
            return SeedEntryStatus(
                text: String(localized: "Invalid seed phrase. Please check your words and try again."),
                tone: .error
            )
        case .unknownWords(let positions):
            return Self.checkWordsStatus(positions)
        case .incomplete:
            return SeedEntryStatus(text: Self.partialText(filled, count), tone: .neutral)
        }
    }

    /// "7 of 25 words". Positional key, so translations can reorder.
    private static func partialText(_ filled: Int, _ count: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString("%1$lld of %2$lld words", comment: "Seed entry: words filled of the total"), filled, count)
    }

    private static func checkWordsStatus(_ positions: [Int]) -> SeedEntryStatus {
        let numbers = positions.map { $0 + 1 }
        if numbers.count == 1 {
            return SeedEntryStatus(text: String(localized: "Check word \(numbers[0])"), tone: .error)
        }
        let list = ListFormatter.localizedString(byJoining: numbers.map { "\($0)" })
        return SeedEntryStatus(text: String(localized: "Check words \(list)"), tone: .error)
    }

    private func updateSuggestions() {
        guard let index = focusedIndex, index < format.wordCount else {
            keyboard.showSuggestions([])
            return
        }
        let text = words[index]
        guard !SeedPhraseValidator.normalize(text).isEmpty else {
            keyboard.showSuggestions([])
            return
        }
        keyboard.showSuggestions(
            SeedPhraseValidator.suggestions(for: text, format: format, committed: settledWords(excluding: index))
        )
    }
}
