import SwiftUI
import UIKit

/// A UITextField subclass that forces the emoji keyboard by overriding textInputMode.
private class EmojiUITextField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
    }
}

/// UIViewRepresentable wrapping EmojiUITextField to force the emoji keyboard.
private struct EmojiTextFieldRepresentable: UIViewRepresentable {
    @Binding var emoji: String
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> EmojiUITextField {
        let tf = EmojiUITextField()
        tf.delegate = context.coordinator
        tf.tintColor = .clear
        tf.textColor = .clear
        tf.backgroundColor = .clear
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        return tf
    }

    func updateUIView(_ tf: EmojiUITextField, context: Context) {
        if isActive && !tf.isFirstResponder {
            DispatchQueue.main.async { tf.becomeFirstResponder() }
        } else if !isActive && tf.isFirstResponder {
            tf.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        let parent: EmojiTextFieldRepresentable
        init(parent: EmojiTextFieldRepresentable) { self.parent = parent }

        func textField(_ tf: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Accept any Character that represents an emoji cluster. Legacy
            // Misc-Symbols / Dingbats emoji (❤️ ☮️ ↩️ ✌️) have
            // isEmojiPresentation == false — they're text-style by default and
            // become emoji only when paired with VS16 (U+FE0F). A naïve
            // `allSatisfy(isEmojiPresentation)` check drops those entire clusters.
            let pickedEmoji = string.last { ch in
                let scalars = ch.unicodeScalars
                if scalars.contains(where: { $0.properties.isEmojiPresentation }) {
                    return true
                }
                // Text-style emoji explicitly promoted to emoji presentation via
                // VS16. Require the cluster to actually contain an emoji-marked
                // scalar above the ASCII / digit range so `#`, `*`, and `0-9`
                // (all flagged isEmoji) aren't mistakenly accepted.
                let hasVS16 = scalars.contains(where: { $0.value == 0xFE0F })
                let hasHighEmojiScalar = scalars.contains {
                    $0.properties.isEmoji && $0.value >= 0x203C
                }
                return hasVS16 && hasHighEmojiScalar
            }
            if let ch = pickedEmoji {
                parent.emoji = String(ch)
                parent.isActive = false
                tf.resignFirstResponder()
            }
            return false
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            parent.isActive = false
        }
    }
}

/// Corner badge that sits on the bottom-right of a wallet avatar circle to
/// mark view-only wallets. Uses the avatar's existing real estate so the
/// wallet name line stays uncluttered — modeled on iOS's app-icon badges.
struct ViewOnlyAvatarBadge: View {
    var body: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.orange))
            .overlay(
                Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5)
            )
            .accessibilityLabel("View-only wallet")
    }
}

/// A tappable emoji circle that opens the system emoji keyboard for picking any emoji.
struct EmojiPickerCircle: View {
    @Binding var emoji: String
    var size: CGFloat = 80
    var fontSize: CGFloat = 44

    /// Keyboard fallback (hidden emoji text field).
    @State private var isActive = false
    @State private var showPicker = false

    var body: some View {
        ZStack {
            Button {
                showPicker = true
            } label: {
                Text(emoji)
                    .font(.system(size: fontSize))
                    .frame(width: size, height: size)
                    // A material over a plain sheet background is invisible in
                    // light mode; use the field fill so the circle always reads.
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(isActive ? Color.orange : Color.clear, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("emojiPicker.circle")
            .accessibilityLabel("Icon, \(EmojiPickerSheet.spokenName(for: emoji))")
            .accessibilityHint("Double tap to choose a different icon")

            EmojiTextFieldRepresentable(emoji: $emoji, isActive: $isActive)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showPicker) {
            EmojiPickerSheet(emoji: $emoji) {
                isActive = true
            }
        }
    }
}

/// Accessible icon picker: a curated grid of emoji as real buttons, each
/// spoken by VoiceOver with its Unicode name, plus a keyboard fallback for
/// anything else. The hidden text-field trick alone could not be activated
/// with VoiceOver and shows nothing on a simulator with a hardware keyboard.
struct EmojiPickerSheet: View {
    @Binding var emoji: String
    var onUseKeyboard: () -> Void
    @Environment(\.dismiss) private var dismiss

    static let choices: [String] = [
        "💰", "💵", "💶", "💷", "💴", "💳", "🪙", "💎", "🏦", "🧾", "📈", "📊",
        "🔐", "🔑", "🗝️", "🛡️", "🔒", "🧰", "🎁", "📦", "🏠", "🏢", "🏝️", "⛺️",
        "🚀", "✈️", "🚗", "⛵️", "🎯", "🎲", "🧩", "🎮", "📱", "💻", "⌚️", "📷",
        "🎧", "🎸", "🎨", "🌍", "🌕", "⭐️", "🔥", "💧", "🌈", "🍀", "🌵", "🌲",
        "🍕", "☕️", "🐱", "🐶", "🦊", "🐻", "🐼", "🦁", "🐸", "🐢", "🦋", "🐝",
        "🟠", "🟢", "🔵", "🟣", "🔴", "⚫️", "⚪️", "🟤"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 10)], spacing: 10) {
                        ForEach(Self.choices, id: \.self) { choice in
                            Button {
                                emoji = choice
                                HapticFeedback.shared.softTick()
                                dismiss()
                            } label: {
                                Text(choice)
                                    .font(.system(size: 30))
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color(.secondarySystemBackground)))
                                    .overlay(
                                        Circle().strokeBorder(choice == emoji ? Color.orange : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.spokenName(for: choice))
                            .accessibilityAddTraits(choice == emoji ? [.isSelected] : [])
                        }
                    }

                    Button {
                        dismiss()
                        onUseKeyboard()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "keyboard")
                                .font(.callout.weight(.semibold))
                            Text("More on the emoji keyboard")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .glassButtonStyle()
                    .accessibilityHint("Opens the emoji keyboard to type any emoji")
                }
                .padding()
            }
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemBackground))
    }

    /// "💰" → "money bag", from the Unicode character name, so VoiceOver has
    /// something to say for an emoji-only control.
    static func spokenName(for emoji: String) -> String {
        guard let raw = emoji.applyingTransform(.toUnicodeName, reverse: false) else { return "icon" }
        let names = raw
            .components(separatedBy: "\\N{")
            .compactMap { part -> String? in
                guard let close = part.firstIndex(of: "}") else { return nil }
                let name = String(part[..<close]).lowercased()
                return name.hasPrefix("variation selector") ? nil : name
            }
        return names.isEmpty ? "icon" : names.joined(separator: " ")
    }
}

/// Wallet switcher chip in the dashboard header: emoji over name. It stays a
/// chip while the list is open; the active wallet keeps its own slot in the
/// list below (check plus orange ring) instead of being pulled up into the
/// chip, so the list never reshuffles on a switch.
struct WalletSwitcherButton: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                Text(walletManager.activeWallet?.emoji ?? "\u{1F4B0}")
                    .font(.system(size: 22))
                Text(walletManager.activeWallet?.name ?? "Wallet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 66)
            }
            .frame(width: 74)
        }
        .glassButtonStyle()
        .accessibilityIdentifier("wallet.switcher")
        .accessibilityHint(isExpanded ? "Closes the wallet list" : "Opens the wallet list, where you can switch, rename or add wallets")
    }
}

/// The outline `.glassButtonStyle()` draws: a capsule under Liquid Glass, the
/// 12pt rounded rectangle of the fallback style. The active row's ring is
/// drawn with it so it sits on the glass edge instead of a guessed inset.
enum WalletRowSurface {
    @ViewBuilder
    static func ring(_ color: Color, lineWidth: CGFloat = 1.5) -> some View {
        if #available(iOS 26.0, *) {
            Capsule().strokeBorder(color, lineWidth: lineWidth)
        } else {
            RoundedRectangle(cornerRadius: 12).strokeBorder(color, lineWidth: lineWidth)
        }
    }
}

/// One wallet row: emoji, name, orange balance, address underneath, a rename
/// pencil, and a check plus an orange ring when it is the active wallet.
///
/// The row is a Button so a tap is a plain button tap: switch, or close the
/// list when it is the active one. The pencil renames.
///
/// Reorder is driven by `WalletManagerRows`: one UIKit long-press recognizer
/// on the enclosing scroll view lifts a row (see `ReorderPressHost`), and the
/// rows draw the lift and slide aside in SwiftUI. This row only needs to know
/// whether it is the lifted one, so its delete swipe stays quiet meanwhile.
///
/// The 20pt horizontal delete swipe reveals the custom Delete zone on
/// inactive rows. VoiceOver stops once per wallet: the row reads the name
/// and balance, and Rename / Delete / Move up / Move down are rotor actions
/// on it.
struct WalletRow: View {
    let wallet: WalletInfo
    let isActive: Bool
    let balance: Decimal
    let address: String?
    let onTap: () -> Void
    let onRename: () -> Void
    /// nil for the active wallet: it is deleted from Settings, not by a swipe.
    let onDelete: (() -> Void)?
    /// nil when the row is already first / last.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    /// True while this row is the one being dragged.
    let isLifted: Bool

    @State private var showDeleteZone = false
    /// True from the moment a horizontal swipe is recognised until just after
    /// it ends, so the release does not fire the row's tap.
    @State private var didSwipe = false

    var body: some View {
        ZStack(alignment: .trailing) {
            if showDeleteZone, let onDelete {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showDeleteZone = false
                    }
                    onDelete()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.red)
                            .clipShape(Circle())
                        Text("Delete")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 12)
                .transition(.opacity)
            }

            rowButton
                // Normal priority, so the scroll view keeps every vertical
                // drag (a high-priority drag here took them all and the list
                // could not scroll); horizontal drags fall through to it,
                // and `didSwipe` keeps that release from tapping.
                .gesture(deleteSwipe)
                .offset(x: showDeleteZone ? -88 : 0)
        }
        .padding(.horizontal)
    }

    /// The tappable row, shared by both paths.
    private var rowButton: some View {
        Button {
            // The release that ends a delete swipe is not a tap.
            guard !didSwipe else { return }
            if showDeleteZone {
                withAnimation(.snappy(duration: 0.25)) { showDeleteZone = false }
            } else {
                onTap()
            }
        } label: {
            rowContent
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .overlay {
            WalletRowSurface.ring(.orange.opacity(isActive ? 0.7 : 0))
        }
        .opacity(isActive ? 1 : 0.85)
        .accessibilityIdentifier(isActive ? "wallet.row.active" : "wallet.row")
        // Name and balance only. The merged label also read the whole
        // 95-character address on every row; the address and icon wait on
        // the More Content rotor instead.
        .accessibilityLabel(spokenLabel)
        .accessibilityCustomContent(AccessibilityCustomContentKey("Address"), address.flatMap { $0.isEmpty ? nil : Text($0) })
        .accessibilityCustomContent("Icon", wallet.emoji)
        .accessibilityHint(isActive ? "Double tap to close the wallet list" : "Double tap to switch to this wallet")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // VoiceOver cannot swipe, long-press, drag, or tap the pencil; all
        // of it is a rotor action on the row itself. SwiftUI hands actions
        // to VoiceOver last first (same on iOS 18.5, 26.1 and 27.0), so
        // they are listed backwards to reach it as Rename, Delete, Move up,
        // Move down.
        .accessibilityActions {
            if let onMoveDown {
                Button("Move down") { onMoveDown() }
            }
            if let onMoveUp {
                Button("Move up") { onMoveUp() }
            }
            if let onDelete {
                Button("Delete") { onDelete() }
            }
            Button("Rename") { onRename() }
        }
        // After the row's accessibility modifiers, so the pencil keeps its own
        // identifier.
        .overlay(alignment: .trailing) {
            // Same trailing slots as `rowContent`: pencil, 14pt gap, the
            // 24pt check or circle, 18pt row padding.
            renameButton
                .padding(.trailing, 18 + 24 + 14)
        }
    }

    /// "Savings, 1.2500 XMR, view-only". The Selected trait marks the
    /// active wallet.
    private var spokenLabel: String {
        var parts = [wallet.name, "\(XMRFormatter.format(balance)) XMR"]
        if wallet.requiresHardwareSession {
            parts.append("hardware wallet")
        } else if wallet.isViewOnly {
            parts.append("view-only")
        }
        return parts.joined(separator: ", ")
    }

    /// The pencil, for touch. A Button of its own so a tap on it renames
    /// instead of switching. Hidden from VoiceOver: as its own element it
    /// put a "Rename" stop before every wallet, and the row already has
    /// Rename as a rotor action.
    private var renameButton: some View {
        Button(action: onRename) {
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
        .accessibilityIdentifier(isActive ? "wallet.switcher.rename" : "wallet.row.rename")
    }

    // MARK: - Content

    private var rowContent: some View {
        HStack(spacing: 14) {
            Text(wallet.emoji)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if wallet.isViewOnly {
                        ViewOnlyAvatarBadge().offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(wallet.name)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 0) {
                    Text(XMRFormatter.format(balance))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                    Text(" XMR")
                        .layoutPriority(1)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)

                // Full address, truncated in the middle to whatever width is
                // left: never wraps, shows more characters on wider rows.
                if let address, !address.isEmpty {
                    Text(address)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }

            Spacer()

            // Holds the pencil's place; the real pencil is `renameButton`,
            // laid over the row outside its Button so its tap renames.
            Color.clear
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Current wallet")
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: - Delete swipe (before iOS 27)

    /// A clear horizontal swipe reveals Delete on inactive rows. Vertical
    /// movement belongs to the scroll view, which cancels this drag when it
    /// starts to pan.
    private var deleteSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard onDelete != nil, !isLifted else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    didSwipe = true
                }
            }
            .onEnded { value in
                defer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didSwipe = false }
                }
                guard onDelete != nil, !isLifted else { return }
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    if dx < -40 {
                        showDeleteZone = true
                    } else if dx > 20 {
                        showDeleteZone = false
                    }
                }
            }
    }
}

/// Expanded wallet manager: EVERY wallet in store order (insertion order until
/// the user drags), the active one marked in place with a check and an orange
/// ring, then Add Wallet. Inline on the dashboard, not a sheet.
///
/// On iOS 27 the rows are a system reorder container: the drop hands back the
/// moved ids and the id they land before, and `applyReorder` persists that
/// order. Before iOS 27 the order changes one slot at a time through the
/// row's context menu; VoiceOver has the same Move up / Move down on every
/// version.
struct WalletManagerRows: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager
    @State private var showAddWallet = false
    @State private var renameWalletId: UUID?
    @State private var renameText = ""
    @State private var renameEmoji = ""
    @State private var deleteWalletId: UUID?
    @State private var isSwitching = false
    /// Guards the destructive Delete button on the confirmation alert —
    /// rapid double-taps would invoke `deleteWallet(id:)` twice and race
    /// the in-flight `completeSwitchToWallet` teardown.
    @State private var isDeleting = false

    private static let rowGap: CGFloat = 10
    /// The snappy spring a nudged row settles on.
    private static let slide = Animation.snappy(duration: 0.3)

    // Drag to reorder. UIKit recognises the press (`ReorderPressHost`),
    // SwiftUI draws it: the lifted row follows the finger through
    // `dragTranslation`, the others slide aside as `dropIndex` changes.
    @State private var dragId: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropIndex: Int?
    /// Row frames in window space, kept current by the rows.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The frames when the lift began; the maths uses these, not the moving ones.
    @State private var framesAtLift: [UUID: CGRect] = [:]
    @State private var liftPoint: CGPoint = .zero
    /// The release that ends a drag reaches the row's Button; swallow it.
    @State private var suppressTapsUntil = Date.distantPast

    private var wallets: [WalletInfo] { walletManager.wallets }

    private var rowsStack: some View {
        VStack(spacing: Self.rowGap) {
            ForEach(wallets) { wallet in
                row(for: wallet)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[wallet.id] = $0 }
                    .offset(y: rowOffset(for: wallet.id))
                    .scaleEffect(dragId == wallet.id ? 1.03 : 1)
                    .zIndex(dragId == wallet.id ? 1 : 0)
                    .animation(dragId == wallet.id ? nil : Self.slide, value: dropIndex)
                    .animation(.snappy(duration: 0.2), value: dragId)
            }

            addWalletButton
        }
        .background {
            ReorderPressHost(
                isEnabled: isExpanded && !isSwitching && !walletManager.isSwitchingWallet,
                shouldBegin: { point in rowId(at: point) != nil },
                onBegan: lift,
                onChanged: move,
                onEnded: drop,
                onCancelled: cancelDrag
            )
        }
    }

    private var addWalletButton: some View {
        Button {
            showAddWallet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Add Wallet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
        .padding(.horizontal)
    }

    var body: some View {
        rowsStack
        .fullScreenCover(isPresented: $showAddWallet, onDismiss: {
            walletManager.addWalletPath = []
        }) {
            AddWalletView()
        }
        .sheet(isPresented: Binding(
            get: { renameWalletId != nil },
            set: { if !$0 { renameWalletId = nil } }
        )) {
            RenameWalletSheet(
                name: $renameText,
                emoji: $renameEmoji,
                onSave: {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let id = renameWalletId, !trimmed.isEmpty {
                        walletManager.renameWallet(id: id, name: trimmed, emoji: renameEmoji)
                    }
                    renameWalletId = nil
                }
            )
            .presentationDetents([.medium])
        }
        .alert("Delete Wallet?", isPresented: Binding(
            get: { deleteWalletId != nil },
            set: { if !$0 { deleteWalletId = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deleteWalletId = nil
                isDeleting = false
            }
            Button("Delete", role: .destructive) {
                guard !isDeleting, let id = deleteWalletId else { return }
                isDeleting = true
                walletManager.deleteWallet(id: id)
                deleteWalletId = nil
                // Reset the guard after the teardown sleep inside
                // `completeSwitchToWallet` would have finished, so a later
                // delete on a different wallet isn't permanently blocked.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isDeleting = false
                }
            }
            .disabled(isDeleting)
        } message: {
            Text("This removes the wallet from this device. You can recover it with the seed phrase.")
        }
    }

    /// One row. The closures read the live list through the manager when
    /// they fire, never an index captured when the row was built.
    private func row(for wallet: WalletInfo) -> some View {
        let isActive = wallet.id == walletManager.activeWallet?.id
        return WalletRow(
            wallet: wallet,
            isActive: isActive,
            balance: isActive ? walletManager.displayBalance : (wallet.cachedBalance ?? 0),
            address: isActive ? walletManager.primaryAddress : wallet.cachedPrimaryAddress,
            onTap: {
                guard dragId == nil, Date() > suppressTapsUntil else { return }
                if isActive {
                    withAnimation(.snappy(duration: 0.35)) { isExpanded = false }
                } else {
                    switchTo(wallet)
                }
            },
            onRename: {
                renameText = wallet.name
                renameEmoji = wallet.emoji
                renameWalletId = wallet.id
            },
            onDelete: isActive ? nil : { deleteWalletId = wallet.id },
            onMoveUp: wallets.first?.id == wallet.id ? nil : { nudge(wallet.id, by: -1) },
            onMoveDown: wallets.last?.id == wallet.id ? nil : { nudge(wallet.id, by: 1) },
            isLifted: dragId == wallet.id
        )
    }

    // MARK: - Drag to reorder

    private func rowId(at point: CGPoint) -> UUID? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// The press began on a row: lift it. Frames are snapshotted here so the
    /// drop maths never sees the rows it is moving.
    private func lift(at point: CGPoint) {
        guard let id = rowId(at: point), let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        framesAtLift = rowFrames
        liftPoint = point
        dragTranslation = 0
        dropIndex = index
        dragId = id
        suppressTapsUntil = .distantFuture
        HapticFeedback.shared.buttonPress()
    }

    private func move(to point: CGPoint) {
        guard let dragId, let frame = framesAtLift[dragId] else { return }
        dragTranslation = point.y - liftPoint.y
        let centerY = frame.midY + dragTranslation
        let others = wallets.filter { $0.id != dragId }.compactMap { framesAtLift[$0.id]?.midY }
        let target = others.filter { $0 < centerY }.count
        if target != dropIndex {
            dropIndex = target
            HapticFeedback.shared.softTick()
        }
    }

    /// Commit: the target and the list are read here, through the manager,
    /// not from values captured when the row was built.
    private func drop(at point: CGPoint) {
        move(to: point)
        guard let id = dragId else { return }
        let target = dropIndex
        suppressTapsUntil = Date().addingTimeInterval(0.3)
        withAnimation(Self.slide) {
            if let target { walletManager.moveWallet(id: id, to: target) }
            dragId = nil
            dragTranslation = 0
            dropIndex = nil
        }
    }

    private func cancelDrag() {
        guard dragId != nil else { return }
        suppressTapsUntil = Date().addingTimeInterval(0.3)
        withAnimation(Self.slide) {
            dragId = nil
            dragTranslation = 0
            dropIndex = nil
        }
    }

    /// Where each row draws while a drag is in flight: the lifted row follows
    /// the finger, the rows between its old and new slot shift by one slot.
    private func rowOffset(for id: UUID) -> CGFloat {
        guard let dragId, let from = wallets.firstIndex(where: { $0.id == dragId }) else { return 0 }
        if id == dragId { return dragTranslation }
        guard let to = dropIndex, to != from, let i = wallets.firstIndex(where: { $0.id == id }) else { return 0 }
        let slot = (framesAtLift[dragId]?.height ?? 0) + Self.rowGap
        if from < to, i > from, i <= to { return -slot }
        if to < from, i >= to, i < from { return slot }
        return 0
    }

    // MARK: - Switching

    private func switchTo(_ wallet: WalletInfo) {
        guard !isSwitching, !walletManager.isSwitchingWallet else { return }
        isSwitching = true

        // Phase 1: batch all @Published changes with the collapse animation
        var switchResult: (target: WalletInfo, previous: WalletInfo?)?
        withAnimation(.snappy(duration: 0.35)) {
            switchResult = walletManager.prepareSwitchToWallet(id: wallet.id)
            if switchResult != nil {
                isExpanded = false
            }
        }
        guard let result = switchResult else {
            isSwitching = false
            return
        }

        // Phase 2: heavy work in background (disk write + wallet start)
        Task {
            try? await walletManager.completeSwitchToWallet(target: result.target, persistPrevious: result.previous)
            isSwitching = false
        }
    }

    // MARK: - Reorder

    /// Context menu and VoiceOver "Move up" / "Move down": one slot, read
    /// from the live list; `moveWallet` clamps the target.
    private func nudge(_ id: UUID, by delta: Int) {
        guard let from = wallets.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Self.slide) {
            walletManager.moveWallet(id: id, to: from + delta)
        }
        UIAccessibility.post(notification: .announcement, argument: delta < 0 ? "Moved up" : "Moved down")
    }
}



/// One UIKit long-press recognizer on the enclosing scroll view, the way
/// UITableView reorders. UIKit arbitrates with the scroll view itself: hold
/// still for 0.4 s and the press begins and the pan is cancelled; move earlier
/// and the press fails and the list scrolls. SwiftUI gesture compositions
/// could not do this inside a ScrollView (each attempt swallowed the vertical
/// drags), the iOS 27 reorder container asserted on every lift, and system
/// drag and drop showed a copy badge. Locations are in window space, which
/// is what the rows report through `frame(in: .global)`.
private struct ReorderPressHost: UIViewRepresentable {
    var isEnabled: Bool
    var shouldBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AttachView {
        let view = AttachView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AttachView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: AttachView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.attach(from: self) }
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if window != nil { coordinator?.attach(from: self) }
        }
        // The hierarchy above a SwiftUI-hosted view can still be assembling
        // when it first lands in a window; keep trying until it is.
        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.attach(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReorderPressHost
        let recognizer = UILongPressGestureRecognizer()
        private weak var scrollView: UIScrollView?

        init(_ parent: ReorderPressHost) {
            self.parent = parent
            super.init()
            recognizer.minimumPressDuration = 0.4
            recognizer.allowableMovement = 10
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        /// Attach to the nearest enclosing UIScrollView so the recognizer sees
        /// every touch that lands on a row (touches reach the recognizers of
        /// every ancestor of the hit view).
        func attach(from view: UIView) {
            guard recognizer.view == nil else { return }
            var candidate = view.superview
            while let current = candidate, !(current is UIScrollView) {
                candidate = current.superview
            }
            guard let scroll = candidate as? UIScrollView else { return }
            scroll.addGestureRecognizer(recognizer)
            scrollView = scroll
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            scrollView?.isScrollEnabled = true
        }

        /// SwiftUI's own recognizer on the hosting view takes every touch
        /// down (that is the Button's pressed state) and is exclusive by
        /// default, which cancelled this press before it could begin. Run
        /// alongside it; the row swallows the tap that ends a lift.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            parent.isEnabled && parent.shouldBegin(gesture.location(in: nil))
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                // Kill the pan for the rest of this touch; re-enabled on release.
                scrollView?.isScrollEnabled = false
                parent.onBegan(point)
            case .changed:
                parent.onChanged(point)
            case .ended:
                scrollView?.isScrollEnabled = true
                parent.onEnded(point)
            case .cancelled, .failed:
                scrollView?.isScrollEnabled = true
                parent.onCancelled()
            default:
                break
            }
        }
    }
}

/// Sheet for renaming a wallet with a tappable emoji picker circle
struct RenameWalletSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                EmojiPickerCircle(emoji: $emoji)
                    .padding(.top, 8)

                Text("Tap to change icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Same field recipe as the Send sheet: label above, 16pt
                // padding, 12pt radius, secondary fill, 16pt screen margins.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wallet Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Wallet Name", text: $name)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .accessibilityLabel("Wallet name")
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Rename Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationBackground(Color(.systemBackground))
    }
}

#Preview {
    @Previewable @State var expanded = false
    VStack {
        HStack(spacing: 0) {
            Text("Good evening")
                .font(.title2.weight(.semibold))
            Spacer(minLength: 12)
            WalletSwitcherButton(isExpanded: $expanded)
                .environmentObject(WalletManager())
        }
        .padding()
        Spacer()
    }
}
