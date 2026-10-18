import SwiftUI

/// The seed input of the restore screen's seed step (spec 2.1): the word
/// count and Paste, the numbered word grid, and the status line with Clear.
/// The step's title, hint and Continue stay in `RestoreWalletView`.
struct SeedPhraseEntryView: View {
    /// The status line's scroll id, for `ScrollViewReader`.
    static let statusID = "seedStatus"

    let model: SeedEntryModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 16) {
            controls
            grid
            statusRow
        }
        .onChange(of: model.status) { _, status in
            let spoken = [status.text, status.detail].compactMap { $0 }.joined(separator: ", ")
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    // MARK: - Word count and Paste

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                countPicker
                pasteButton
            }
            VStack(spacing: 12) {
                countPicker
                pasteButton
            }
        }
    }

    /// At the accessibility text sizes the segments show the number only
    /// ("16 words" breaks mid-word there); VoiceOver still reads "16 words".
    private var countPicker: some View {
        let numbersOnly = dynamicTypeSize.isAccessibilitySize
        return GlassSegmentedPicker(
            selection: Binding(get: { model.format }, set: { model.setFormat($0) }),
            accessibilityLabel: { format in String(localized: "\(format.wordCount) words") },
            label: { format in
                numbersOnly ? format.wordCount.formatted() : String(localized: "\(format.wordCount) words")
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Number of words"))
        .accessibilityIdentifier("restore.wordCount")
    }

    /// The system paste control: it pastes without the "Allow Paste" prompt.
    private var pasteButton: some View {
        SeedPasteControl { text in
            model.paste(text)
        }
        .fixedSize()
        .accessibilityIdentifier("restore.pasteButton")
    }

    // MARK: - Grid

    private var grid: some View {
        SeedGridLayout(minColumnWidth: 150, spacing: 8, singleColumn: dynamicTypeSize.isAccessibilitySize) {
            ForEach(0..<model.wordCount, id: \.self) { index in
                SeedWordCell(index: index, model: model)
                    .id(index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Seed Phrase"))
    }

    // MARK: - Status

    /// Status leading, Clear trailing; at the accessibility text sizes Clear
    /// goes under the status, so the status keeps the full width.
    private var statusRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let glyph = statusGlyph {
                        Image(systemName: glyph)
                            .accessibilityHidden(true)
                    }
                    Text(model.status.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("restore.seedStatus")

                if let detail = model.status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("restore.seedBirthday")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.hasText {
                Button {
                    model.clearAll()
                } label: {
                    Text("Clear")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("restore.clearButton")
            }
        }
        .frame(minHeight: 44)
        .id(Self.statusID)
    }

    private var statusGlyph: String? {
        switch model.status.tone {
        case .neutral: return nil
        case .error: return "exclamationmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.status.tone {
        case .neutral: return .secondary
        case .error: return .red
        case .success: return .green
        }
    }
}

/// One numbered cell: "N." in secondary, the word in monospaced text.
/// Focused cells get a brand stroke; invalid ones a red stroke, red text and
/// an error glyph, so the state never rests on color alone.
private struct SeedWordCell: View {
    let index: Int
    let model: SeedEntryModel

    var body: some View {
        let isInvalid = model.invalidCells.contains(index)
        let isFocused = model.focusedIndex == index
        HStack(spacing: 8) {
            Text(verbatim: "25.")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: "\(index + 1).")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.monospacedDigit())
                .accessibilityHidden(true)

            SeedWordField(
                index: index,
                text: model.words[index],
                isInvalid: isInvalid,
                isLast: index == model.wordCount - 1,
                model: model
            )

            if isInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isInvalid ? Color.red : (isFocused ? Color.brand : Color.clear), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            model.keyboard.focus(index)
        }
    }
}

/// Equal columns, filled left to right then down. The count follows the
/// width (2 on a phone, 4 in the wide seed column of the Duo inner display),
/// 1 at the accessibility text sizes. Not lazy: every visible cell's text field
/// exists, so focus can move to any of them.
private struct SeedGridLayout: Layout {
    let minColumnWidth: CGFloat
    let spacing: CGFloat
    let singleColumn: Bool

    private func columns(for width: CGFloat) -> Int {
        guard !singleColumn else { return 1 }
        // Half a point of slack, so a width of exactly n columns is n.
        return max(1, Int((width + spacing + 0.5) / (minColumnWidth + spacing)))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columnWidth: CGFloat, columns: Int, heights: [CGFloat]) {
        let columns = columns(for: width)
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var heights: [CGFloat] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + columns, subviews.count)
            let height = subviews[start..<end]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            heights.append(height)
            start = end
        }
        return (columnWidth, columns, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minColumnWidth * 2 + spacing)
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + CGFloat(max(0, layout.heights.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.columnWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: layout.columnWidth, height: height)
                )
            }
            y += height + spacing
        }
    }
}

/// `UIPasteControl` with the brand label on the field fill (SwiftUI's
/// `PasteButton` cannot set its label color). A paste control reads the
/// clipboard without the "Allow Paste" prompt.
private struct SeedPasteControl: UIViewRepresentable {
    let onPaste: (String) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        var configuration = UIPasteControl.Configuration()
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.baseForegroundColor = .brand
        configuration.cornerStyle = .capsule
        configuration.displayMode = .iconAndLabel
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    /// The control's own size (it grows with Dynamic Type, and the system
    /// requires the whole label to show), at least the 44pt target.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        let fitting = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: max(fitting.width, 44), height: max(fitting.height, 44))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    final class Coordinator: UIResponder {
        var onPaste: (String) -> Void

        init(onPaste: @escaping (String) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                DispatchQueue.main.async {
                    self?.onPaste(text)
                }
            }
        }
    }
}
