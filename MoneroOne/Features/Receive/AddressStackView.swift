import SwiftUI

/// Every receiving address as a card: the main address pinned first,
/// subaddresses newest first with runs of unused spares folded, search from
/// nine addresses. On iPhone the cards fan out over Receive and overlap like
/// a Wallet stack (`.stack`); on iPad and the unfolded Duo they sit beside
/// the Receive card as a flat column (`.column`). The cards borrow the
/// wallet row's details: the pencil, the orange amount, the green check.
struct AddressCardsView: View {
    enum Layout: Equatable {
        /// Fanned over Receive while open; collapsed onto the first card
        /// and hidden while closed.
        case stack(isOpen: Bool)
        case column
    }

    let layout: Layout
    let mainRow: ReceiveAddressRow?
    /// Newest first.
    let rows: [ReceiveAddressRow]
    let selectedIndex: Int
    let isCreating: Bool
    let canCreate: Bool
    let onUse: (Int) -> Void
    let onCreate: () -> Void
    let onSaveLabel: (Int, String) -> Void
    /// The stack's escape gesture; nil in the column.
    var onClose: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var expandedRuns: Set<Int> = []
    @State private var renamingIndex: Int?
    @State private var draft = ""
    /// The card tapped to use: it rises into the Receive card while the
    /// others fall away.
    @State private var chosenIndex: Int?
    @FocusState private var fieldFocused: Bool

    /// How far each stacked card starts below the one before it: its name,
    /// short address and amount show; the rest sits under the next card.
    /// Grows with the text size so the next card never covers the name.
    @ScaledMetric(relativeTo: .subheadline) private var step: CGFloat = 76
    private var cardHeight: CGFloat { step + 48 }

    private var isStack: Bool {
        if case .stack = layout { return true }
        return false
    }

    private var isOpen: Bool {
        if case .stack(let open) = layout { return open }
        return true
    }

    private var addressCount: Int {
        rows.count + (mainRow == nil ? 0 : 1)
    }

    private var items: [ReceiveAddressListItem] {
        ReceiveAddressLogic.stackItems(
            main: mainRow,
            rows: rows,
            selectedIndex: selectedIndex,
            expandedRuns: expandedRuns,
            search: search
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if ReceiveAddressLogic.showsSearch(addressCount: addressCount) {
                    searchField
                        .padding(.bottom, 16)
                        .modifier(StackFan(index: 0, isOpen: isOpen, collapse: 0, reduceMotion: reduceMotion))
                }

                let list = items
                if list.isEmpty {
                    Text("No matching addresses", comment: "Address list: search found nothing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                VStack(spacing: isStack ? step - cardHeight : 10) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { position, item in
                        card(item, isLast: position == list.count - 1)
                            .modifier(StackFan(
                                index: position,
                                isOpen: isOpen,
                                collapse: isStack ? CGFloat(position) * step : 0,
                                reduceMotion: reduceMotion,
                                isChosen: isChosen(item)
                            ))
                    }
                }

                if rows.isEmpty && search.isEmpty {
                    emptyState
                        .padding(.top, 16)
                        .modifier(StackFan(index: 1, isOpen: isOpen, collapse: 0, reduceMotion: reduceMotion))
                }

                // Names are typed in place now, so the note the rename
                // sheet carried sits under the cards.
                Text("Labels stay on this device and aren't backed up with your seed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .modifier(StackFan(index: min(list.count, 10), isOpen: isOpen, collapse: 0, reduceMotion: reduceMotion))
            }
            .padding(.horizontal, isStack ? 16 : 0)
            .padding(.top, isStack ? 8 : 0)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(isStack ? .automatic : .hidden)
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .modifier(EscapeAction(action: onClose))
        .onChange(of: fieldFocused) { _, focused in
            if !focused { commitRename() }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                chosenIndex = nil
            } else {
                commitRename()
                search = ""
            }
        }
    }

    private func isChosen(_ item: ReceiveAddressListItem) -> Bool {
        if case .address(let row) = item { return row.index == chosenIndex }
        return false
    }

    // MARK: Cards

    @ViewBuilder
    private func card(_ item: ReceiveAddressListItem, isLast: Bool) -> some View {
        switch item {
        case .address(let row):
            AddressStrip(
                row: row,
                isSelected: row.index == selectedIndex,
                isRenaming: renamingIndex == row.index,
                draft: $draft,
                fieldFocused: $fieldFocused,
                minHeight: isStack ? cardHeight : nil,
                showsPreview: isStack && isLast,
                onUse: { use(row) },
                onRename: row.isMain ? nil : { beginRename(row) },
                onCommitRename: commitRename
            )
        case .unusedRun(let run):
            foldedRun(run, isLast: isLast)
        }
    }

    /// A folded run keeps the stack's card height where the next card
    /// overlaps it; last, nothing does, so it takes its own height instead
    /// of an empty card.
    private func foldedRun(_ run: [ReceiveAddressRow], isLast: Bool) -> some View {
        let low = run.map(\.index).min() ?? 0
        let high = run.map(\.index).max() ?? 0
        let title = String(localized: "\(run.count) unused addresses", comment: "Address list: a folded run of unused subaddresses")
        let range = String(localized: "#\(low) to #\(high)", comment: "Address list: the numbers a folded run covers")
        return Button {
            HapticFeedback.shared.softTick()
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)) {
                _ = expandedRuns.insert(run.first?.index ?? high)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: isStack && !isLast ? cardHeight : nil, alignment: .topLeading)
            .background { StripSurface(style: .muted, isSelected: false) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + range)
        .accessibilityHint(String(localized: "Shows these addresses", comment: "VoiceOver hint: unfolds a run of unused addresses"))
        .accessibilityAddTraits(.isButton)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "Name, #number or address", comment: "Address list: search field placeholder"), text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(String(localized: "Search addresses", comment: "VoiceOver: the address list's search field"))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search", comment: "VoiceOver: clears the address search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No subaddresses yet")
                .font(.subheadline.weight(.semibold))
            Text("A new address for each payer keeps their payments apart.", comment: "Address list: empty state help")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onCreate) {
                Text("New Address", comment: "Address list: empty state button")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .glassButtonStyle()
            .disabled(!canCreate || isCreating)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background { StripSurface(style: .plain, isSelected: false) }
    }

    // MARK: Actions

    private func use(_ row: ReceiveAddressRow) {
        commitRename()
        chosenIndex = row.index
        onUse(row.index)
    }

    private func beginRename(_ row: ReceiveAddressRow) {
        if renamingIndex != nil { commitRename() }
        HapticFeedback.shared.softTick()
        draft = row.label
        renamingIndex = row.index
        // The field exists from the next render on.
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename() {
        guard let index = renamingIndex else { return }
        let current = (index == 0 ? mainRow : rows.first { $0.index == index })?.label ?? ""
        renamingIndex = nil
        fieldFocused = false
        if let label = ReceiveAddressLogic.labelToSave(draft: draft, current: current) {
            onSaveLabel(index, label)
        }
    }
}

/// The stack's fan: closed, every card sits on the first one, a little
/// smaller and transparent; open, each card drops to its place with the
/// shared spring, 30 ms after the one above it. Closing on a pick, the
/// chosen card rises to the top at full size and fades last, handing over
/// to the Receive card; the others fade at once. Reduce Motion fades only.
private struct StackFan: ViewModifier {
    let index: Int
    let isOpen: Bool
    /// How far this card moves up to sit on the first one while closed.
    let collapse: CGFloat
    let reduceMotion: Bool
    var isChosen = false

    func body(content: Content) -> some View {
        let moves = !isOpen && !reduceMotion
        content
            .offset(y: moves ? (isChosen ? -collapse : -collapse - 24) : 0)
            .scaleEffect(moves && !isChosen ? 0.96 : 1, anchor: .top)
            .animation(motion, value: isOpen)
            .opacity(isOpen ? 1 : 0)
            .animation(fade, value: isOpen)
    }

    private var stagger: Double { Double(min(index, 10)) * 0.03 }

    private var motion: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        let spring = Animation.spring(response: 0.5, dampingFraction: 0.86)
        return isOpen ? spring.delay(stagger) : spring
    }

    private var fade: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        if isOpen { return .easeOut(duration: 0.25).delay(stagger) }
        return isChosen ? .easeIn(duration: 0.2).delay(0.25) : .easeOut(duration: 0.18)
    }
}

/// VoiceOver's escape gesture closes the stack; the column beside the
/// Receive card leaves it to the sheet.
private struct EscapeAction: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(.escape, action)
        } else {
            content
        }
    }
}

/// A card's surface: the Receive card's fill, a hairline in dark mode, a
/// shadow cast upward onto the card behind, and the wallet row's orange
/// ring on the shown address.
private struct StripSurface: View {
    enum Style { case plain, main, muted }

    let style: Style
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(fill)
            .overlay {
                if style == .main {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.06))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.orange.opacity(0.7) : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.04),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .shadow(color: .black.opacity(colorScheme == .light ? 0.10 : 0.45), radius: 10, y: -2)
    }

    private var fill: Color {
        switch style {
        case .muted:
            return colorScheme == .dark ? Color(.tertiarySystemGroupedBackground) : Color(.systemGray6)
        case .plain, .main:
            return colorScheme == .dark ? Color(.secondarySystemGroupedBackground) : Color(.systemBackground)
        }
    }
}

/// One address card: the name (and its number when it has a label), the
/// short address, what it received in the wallet row's orange or "Unused",
/// the wallet row's pencil and green check. The pencil renames in place;
/// Return saves. VoiceOver reads one element per address with Use, Copy
/// Address and Rename as rotor actions.
struct AddressStrip: View {
    let row: ReceiveAddressRow
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var draft: String
    var fieldFocused: FocusState<Bool>.Binding
    /// The stack's fixed card height; nil in the column.
    var minHeight: CGFloat?
    /// The last stack card shows the address under its top line; the
    /// others hide it under the next card.
    var showsPreview = false
    let onUse: () -> Void
    /// nil for the main address: it takes no label.
    let onRename: (() -> Void)?
    let onCommitRename: () -> Void

    var body: some View {
        Group {
            if isRenaming {
                content
            } else {
                Button(action: onUse) {
                    content
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(action: copy) {
                        Label(String(localized: "Copy Address", comment: "Copies a receiving address"), systemImage: "doc.on.doc")
                    }
                    if let onRename {
                        Button(action: onRename) {
                            Label(String(localized: "Rename"), systemImage: "pencil")
                        }
                    }
                }
                // One element per address; the whole address waits on the
                // More Content rotor. SwiftUI hands actions to VoiceOver last
                // first, so they are listed backwards to read Use, Copy
                // Address, Rename.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ReceiveAddressLogic.spokenRow(row))
                .accessibilityCustomContent(AccessibilityCustomContentKey("Address"), Text(verbatim: row.address))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(String(localized: "Double tap to show this address on Receive", comment: "VoiceOver hint: selects an address in the list"))
                .accessibilityActions {
                    if let onRename {
                        Button(String(localized: "Rename"), action: onRename)
                    }
                    Button(String(localized: "Copy Address", comment: "Copies a receiving address"), action: copy)
                    Button(String(localized: "Use This Address", comment: "VoiceOver rotor action: shows this address on the Receive card"), action: onUse)
                }
                .accessibilityIdentifier("addresses.row.\(row.index)")
                // After the row's accessibility modifiers, so the pencil
                // keeps its own tap: a tap on it renames instead of using.
                .overlay(alignment: .topTrailing) {
                    if onRename != nil {
                        // The placeholder's slot: 14pt from the top, and
                        // the 16pt padding, the check and a 12pt gap from
                        // the trailing edge.
                        pencil
                            .padding(.top, 14)
                            .padding(.trailing, 16 + 24 + 12)
                    }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    // 12…8 characters, or 8…6 in a narrow column, never cut.
                    ViewThatFits(in: .horizontal) {
                        shortAddress(head: 12, tail: 8)
                        shortAddress(head: 8, tail: 6)
                        shortAddress(head: 6, tail: 4)
                    }
                }
                Spacer(minLength: 8)
                amount
                if onRename != nil {
                    // Holds the pencil's place; the real pencil is laid over
                    // the card outside its Button.
                    Color.clear
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                check
            }
            if showsPreview {
                Text(verbatim: groupedPrefix)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background {
            StripSurface(style: row.isMain ? .main : .plain, isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: 6) {
            if isRenaming {
                TextField(row.name, text: $draft)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused(fieldFocused)
                    .onSubmit(onCommitRename)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.6))
                    }
                    .accessibilityLabel(String(localized: "Address name", comment: "VoiceOver: the field that renames a subaddress in place"))
                    .accessibilityIdentifier("addresses.renameField")
            } else if row.isMain {
                // The chip goes under the name when the card also shows a
                // total, rather than cut "Main Address".
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        nameText
                        linksChip
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        nameText
                        linksChip
                    }
                }
            } else {
                nameText
                if row.isLabeled {
                    Text(verbatim: "#\(row.index)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var nameText: some View {
        Text(row.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var amount: some View {
        if row.isUsed {
            // The wallet row's balance style.
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(XMRFormatter.formatCompact(row.usage.received)) XMR")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Text(ReceiveAddressLogic.paymentCount(row.usage.payments))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
        } else {
            Text("Unused", comment: "Address list: an address with no payments yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var check: some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// The wallet row's pencil. Hidden from VoiceOver: Rename is a rotor
    /// action on the card.
    private var pencil: some View {
        Button {
            onRename?()
        } label: {
            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(width: 24, height: 24)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-10)
        .accessibilityHidden(true)
        .accessibilityIdentifier("addresses.row.\(row.index).rename")
    }

    private func shortAddress(head: Int, tail: Int) -> some View {
        Text(verbatim: ReceiveAddressLogic.shortAddress(row.address, head: head, tail: tail))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var linksChip: some View {
        Text("Links payments", comment: "Address list: chip on the main address row")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    /// The first 24 characters in groups of four, for the last card.
    private var groupedPrefix: String {
        let head = Array(row.address.prefix(24))
        let groups = stride(from: 0, to: head.count, by: 4).map { String(head[$0..<min($0 + 4, head.count)]) }
        return groups.joined(separator: " ") + " …"
    }

    private func copy() {
        UIPasteboard.general.string = row.address
        HapticFeedback.shared.softTick()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Address copied"))
    }
}

// MARK: - Labels

/// Splits a wallet2 label into a leading emoji grapheme (if any) and remaining name.
/// wallet2 stores a single `std::string` per subaddress, so we pack "<emoji> <name>"
/// and parse on edit.
func splitSubaddressLabel(_ raw: String) -> (emoji: String, name: String) {
    guard let first = raw.first else { return ("", "") }
    let isEmoji = first.unicodeScalars.contains {
        $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C)
    }
    if isEmoji {
        let name = raw.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), name)
    }
    return ("", raw)
}

/// Packs emoji + name back into wallet2's label string.
func joinSubaddressLabel(emoji: String, name: String) -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    if emoji.isEmpty { return trimmedName }
    if trimmedName.isEmpty { return emoji }
    return "\(emoji) \(trimmedName)"
}
