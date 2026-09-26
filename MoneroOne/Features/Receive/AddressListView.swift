import SwiftUI

/// Every receiving address: the main address pinned on top, subaddresses
/// newest first with runs of unused spares folded, search above eight
/// addresses. Pushed from Receive on iPhone; beside the card on iPad and
/// the unfolded Duo (`inline`), where it has no bar of its own.
struct AddressListView: View {
    enum Mode { case pushed, inline }

    let mode: Mode
    let mainRow: ReceiveAddressRow?
    /// Newest first.
    let rows: [ReceiveAddressRow]
    let selectedIndex: Int
    let isCreating: Bool
    let canCreate: Bool
    let onSelect: (Int) -> Void
    let onRename: (ReceiveAddressRow) -> Void
    let onCreate: () -> Void

    @State private var search = ""
    @State private var expandedRuns: Set<Int> = []

    private var showsSearch: Bool {
        rows.count + 1 > ReceiveAddressLogic.searchThreshold
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List {
            if showsSearch {
                Section {
                    searchField
                }
            }

            // No header: the row is titled "Main Address" already.
            if let mainRow, ReceiveAddressLogic.matches(mainRow, search: search) {
                Section {
                    rowView(mainRow)
                }
            }

            Section {
                if rows.isEmpty {
                    emptyState
                } else if isSearching {
                    let found = rows.filter { ReceiveAddressLogic.matches($0, search: search) }
                    if found.isEmpty {
                        Text("No matching addresses", comment: "Address list: search found nothing")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(found) { rowView($0) }
                } else {
                    ForEach(ReceiveAddressLogic.listItems(rows, selectedIndex: selectedIndex, expandedRuns: expandedRuns)) { item in
                        switch item {
                        case .address(let row):
                            rowView(row)
                        case .unusedRun(let run):
                            foldedRun(run)
                        }
                    }
                }
            } header: {
                Text("Subaddresses")
            }
        }
        .listStyle(.insetGrouped)
        .modifier(PushedChrome(mode: mode, isCreating: isCreating, canCreate: canCreate, onCreate: onCreate))
    }

    // MARK: Rows

    private func rowView(_ row: ReceiveAddressRow) -> some View {
        AddressListRow(
            row: row,
            isSelected: row.index == selectedIndex,
            onSelect: { onSelect(row.index) },
            onRename: row.isMain ? nil : { onRename(row) }
        )
    }

    private func foldedRun(_ run: [ReceiveAddressRow]) -> some View {
        let low = run.map(\.index).min() ?? 0
        let high = run.map(\.index).max() ?? 0
        return Button {
            HapticFeedback.shared.softTick()
            withAnimation(.snappy(duration: 0.3)) {
                _ = expandedRuns.insert(run.first?.index ?? high)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "\(run.count) unused addresses", comment: "Address list: a folded run of unused subaddresses"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "#\(low) to #\(high)", comment: "Address list: the numbers a folded run covers"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(run.count) unused addresses", comment: "Address list: a folded run of unused subaddresses") + ", " + String(localized: "#\(low) to #\(high)", comment: "Address list: the numbers a folded run covers"))
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
        .listRowBackground(Color.clear)
    }
}

/// The pushed list's title and "+" button. Inline, the list sits in the
/// Receive page and borrows its bar, so it adds none.
private struct PushedChrome: ViewModifier {
    let mode: AddressListView.Mode
    let isCreating: Bool
    let canCreate: Bool
    let onCreate: () -> Void

    func body(content: Content) -> some View {
        switch mode {
        case .inline:
            content
        case .pushed:
            content
                .navigationTitle(String(localized: "Addresses", comment: "Title of the receiving address list"))
                .navigationBarTitleDisplayMode(.inline)
                .horizontalBarsOnDuo()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onCreate) {
                            if isCreating {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                        }
                        .disabled(!canCreate || isCreating)
                        .accessibilityLabel(String(localized: "New address", comment: "VoiceOver: the Receive card's New button"))
                        .accessibilityIdentifier("addresses.newButton")
                    }
                }
        }
    }
}

/// One address: name (and number when it has a label), the short address,
/// what it received or "Unused", and a check on the shown one. Copy and
/// Rename sit in the swipe, the context menu and the VoiceOver rotor.
struct AddressListRow: View {
    let row: ReceiveAddressRow
    let isSelected: Bool
    let onSelect: () -> Void
    var onRename: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // The main address's chip goes under its name when the
                    // row also shows a total, rather than cut the name.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            title
                            if row.isMain { linksChip }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            title
                            if row.isMain { linksChip }
                        }
                    }
                    // 12…8 characters, or 8…6 in a narrow column, never cut.
                    ViewThatFits(in: .horizontal) {
                        shortAddress(head: 12, tail: 8)
                        shortAddress(head: 8, tail: 6)
                        shortAddress(head: 6, tail: 4)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    if row.isUsed {
                        Text(verbatim: "+\(XMRFormatter.formatCompact(row.usage.received)) XMR")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                        Text(ReceiveAddressLogic.paymentCount(row.usage.payments))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Unused", comment: "Address list: an address with no payments yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onRename {
                Button(action: onRename) {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
                .tint(.orange)
            }
            Button(action: copy) {
                Label(String(localized: "Copy Address", comment: "Copies a receiving address"), systemImage: "doc.on.doc")
            }
            .tint(.gray)
        }
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
        // One element per address. The whole address waits on the More
        // Content rotor. SwiftUI hands actions to VoiceOver last first, so
        // they are listed backwards to read Copy Address, then Rename.
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
        }
        .accessibilityIdentifier("addresses.row.\(row.index)")
    }

    /// The name, and the number beside a label so search by number makes sense.
    private var title: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if row.isLabeled && !row.isMain {
                Text(verbatim: "#\(row.index)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortAddress(head: Int, tail: Int) -> some View {
        Text(verbatim: ReceiveAddressLogic.shortAddress(row.address, head: head, tail: tail))
            .font(.caption.monospaced())
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

// MARK: - Rename Subaddress Sheet

struct RenameSubaddressSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                EmojiPickerCircle(emoji: $emoji)
                    .padding(.top, 8)

                Text("Tap to change icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Label")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Label", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .accessibilityLabel("Subaddress label")
                    Text("Labels stay on this device and aren't backed up with your seed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Rename Subaddress")
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}
