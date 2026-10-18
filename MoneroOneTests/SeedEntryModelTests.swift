import XCTest
import UIKit
@testable import MoneroOne

/// The word count control on the seed entry screen (spec 2.2). Another count
/// starts over with an empty grid; the selected count does nothing; a paste
/// that fits another count switches it and keeps the pasted words.
@MainActor
final class SeedEntryModelTests: XCTestCase {

    private let legacy = LegacySeedCodecTests.vector
    private let bip39 = Array(repeating: "abandon", count: 23) + ["art"]
    private let polyseed = PolyseedCodecTests.phraseEn1.split(separator: " ").map(String.init)

    private var emptyWords: [String] { Array(repeating: "", count: SeedEntryModel.cellCount) }

    /// Typed words: three words on the English legacy and BIP39 lists, an
    /// unknown word (cell 4 shows the invalid mark), a prefix in the focused
    /// cell 5 (the suggestions) and, on the 25-word grid, word 25, past the
    /// 16- and 24-word grids.
    private func typeWords(into model: SeedEntryModel) {
        for (i, word) in ["ability", "absorb", "adapt", "zzzz"].enumerated() {
            model.setText(word, at: i)
            model.commit(i, advance: false)
        }
        if model.format == .legacy {
            model.setText("rudely", at: 24)
            model.commit(24, advance: false)
        }
        model.didBeginEditing(4)
        model.setText("pe", at: 4)
    }

    private func suggestions(_ model: SeedEntryModel) -> [String] {
        (model.keyboard.suggestionBar.items ?? []).compactMap(\.title)
    }

    /// The status line of an untouched grid with this count.
    private func emptyStatus(_ format: SeedFormat) -> SeedEntryStatus {
        let fresh = SeedEntryModel()
        fresh.setFormat(format)
        return fresh.status
    }

    private func assertEmpty(_ model: SeedEntryModel, _ format: SeedFormat, line: UInt = #line) {
        XCTAssertEqual(model.format, format, line: line)
        XCTAssertEqual(model.words, emptyWords, line: line)
        XCTAssertEqual(model.committed, Array(repeating: false, count: SeedEntryModel.cellCount), line: line)
        XCTAssertFalse(model.hasText, line: line)
        XCTAssertTrue(model.invalidCells.isEmpty, line: line)
        XCTAssertFalse(model.showsCountError, line: line)
        XCTAssertNil(model.externalError, line: line)
        XCTAssertEqual(model.outcome, .incomplete, line: line)
        XCTAssertEqual(model.status, emptyStatus(format), line: line)
        XCTAssertEqual(model.status.tone, .neutral, line: line)
        XCTAssertTrue(suggestions(model).isEmpty, line: line)
    }

    // MARK: - Another count clears

    func testAnotherCountClearsEveryWord() {
        for (start, next) in [(SeedFormat.legacy, SeedFormat.polyseed), (.legacy, .bip39), (.bip39, .legacy), (.polyseed, .bip39)] {
            let model = SeedEntryModel()
            model.setFormat(start)
            typeWords(into: model)
            XCTAssertEqual(model.invalidCells, [3])
            XCTAssertEqual(model.status.tone, .error)
            XCTAssertFalse(suggestions(model).isEmpty)

            model.setFormat(next)

            assertEmpty(model, next)
        }
    }

    /// The old grid kept the words past a smaller count and showed them
    /// again when the count grew back.
    func testWordsPastASmallerCountDoNotComeBack() {
        let model = SeedEntryModel()
        typeWords(into: model)
        XCTAssertEqual(model.words[24], "rudely")

        model.setFormat(.polyseed)
        model.setFormat(.legacy)

        assertEmpty(model, .legacy)
    }

    func testAnotherCountClearsTheErrors() {
        let model = SeedEntryModel()
        typeWords(into: model)
        model.insert(["sequence", "atlas"], at: nil)
        XCTAssertTrue(model.showsCountError)
        model.setFormat(.bip39)
        assertEmpty(model, .bip39)

        typeWords(into: model)
        model.showError("This seed phrase is already used")
        XCTAssertNotNil(model.externalError)
        model.setFormat(.legacy)
        assertEmpty(model, .legacy)
    }

    // MARK: - The selected count

    func testTheSelectedCountChangesNothing() {
        for format in SeedFormat.allCases {
            let model = SeedEntryModel()
            model.setFormat(format)
            typeWords(into: model)
            let words = model.words
            let committed = model.committed
            let status = model.status
            let shown = suggestions(model)
            let scroll = model.scrollRequest

            model.setFormat(format)

            XCTAssertEqual(model.format, format)
            XCTAssertEqual(model.words, words)
            XCTAssertEqual(model.committed, committed)
            XCTAssertEqual(model.invalidCells, [3])
            XCTAssertEqual(model.focusedIndex, 4)
            XCTAssertEqual(model.status, status)
            XCTAssertEqual(suggestions(model), shown)
            XCTAssertFalse(shown.isEmpty)
            XCTAssertEqual(model.scrollRequest?.serial, scroll?.serial)
        }
    }

    // MARK: - Paste that switches the count

    /// The Paste button (no cell) and a paste into a cell: the grid takes the
    /// pasted count and the pasted words, and the words typed before go.
    func testPasteThatSwitchesTheCountKeepsThePastedWords() {
        let phrases: [(SeedFormat, [String])] = [(.legacy, legacy), (.bip39, bip39), (.polyseed, polyseed)]
        for (format, phrase) in phrases {
            for start in SeedFormat.allCases where start != format {
                for cell in [nil, 2] as [Int?] {
                    let model = SeedEntryModel()
                    model.setFormat(start)
                    typeWords(into: model)

                    model.insert(SeedPasteParser.parse(phrase.joined(separator: " ")), at: cell)

                    let label = "\(phrase.count) words pasted on the \(start.wordCount)-word grid, cell \(String(describing: cell))"
                    XCTAssertEqual(model.format, format, label)
                    XCTAssertEqual(Array(model.words.prefix(format.wordCount)), phrase, label)
                    XCTAssertTrue(model.words.dropFirst(format.wordCount).allSatisfy(\.isEmpty), label)
                    XCTAssertEqual(model.validWords, phrase, label)
                    XCTAssertEqual(model.status.tone, .success, label)

                    // The control now shows the pasted count; selecting it
                    // again keeps the words.
                    model.setFormat(format)
                    XCTAssertEqual(Array(model.words.prefix(format.wordCount)), phrase, label)
                    XCTAssertEqual(model.validWords, phrase, label)
                }
            }
        }
    }

    // MARK: - Focus and the text fields

    /// Real cells in a window: focus goes from the focused cell to word 1,
    /// no field keeps text (an IME composition too), and with no focused
    /// cell the keyboard stays down.
    func testFocusMovesToWordOneAndNoFieldKeepsText() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()

        let model = SeedEntryModel()
        var coordinators: [SeedWordField.Coordinator] = []
        var fields: [SeedWordTextField] = []
        for i in 0..<SeedEntryModel.cellCount {
            let cell = SeedWordField(index: i, text: "", isInvalid: false, isLast: i == SeedEntryModel.cellCount - 1, model: model)
            let coordinator = cell.makeCoordinator()
            let field = SeedWordTextField(frame: CGRect(x: 0, y: 60 + CGFloat(i) * 30, width: 200, height: 28))
            field.delegate = coordinator
            field.addTarget(coordinator, action: #selector(SeedWordField.Coordinator.editingChanged(_:)), for: .editingChanged)
            root.view.addSubview(field)
            model.keyboard.register(field, at: i)
            coordinators.append(coordinator)
            fields.append(field)
        }
        defer {
            model.keyboard.dismiss()
            window.isHidden = true
            withExtendedLifetime(coordinators) {}
        }
        let texts = { fields.map { $0.text ?? "" } }

        // A word in cell 1 and a prefix in the focused cell 6.
        model.keyboard.focus(0)
        fields[0].insertText("atlas")
        model.keyboard.focus(5)
        fields[5].insertText("pe")
        XCTAssertEqual(model.focusedIndex, 5)
        XCTAssertEqual(model.words[5], "pe")
        XCTAssertEqual(model.words[0], "atlas")

        model.setFormat(.bip39)

        XCTAssertTrue(fields[0].isFirstResponder)
        XCTAssertEqual(model.focusedIndex, 0)
        XCTAssertEqual(texts(), emptyWords)
        assertEmpty(model, .bip39)

        // An IME composition in word 1 when the count changes.
        fields[0].setMarkedText("ぺ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(fields[0].markedTextRange)
        model.setFormat(.polyseed)
        XCTAssertNil(fields[0].markedTextRange)
        XCTAssertEqual(texts(), emptyWords)
        XCTAssertEqual(model.focusedIndex, 0)
        assertEmpty(model, .polyseed)

        // No focused cell: the keyboard stays down.
        model.keyboard.focus(2)
        fields[2].insertText("pe")
        model.keyboard.dismiss()
        XCTAssertNil(model.focusedIndex)
        model.setFormat(.legacy)
        XCTAssertFalse(fields.contains { $0.isFirstResponder })
        XCTAssertNil(model.focusedIndex)
        XCTAssertEqual(texts(), emptyWords)
        assertEmpty(model, .legacy)
    }
}
