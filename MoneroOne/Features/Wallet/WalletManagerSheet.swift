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
        .accessibilityHint(isExpanded ? "Closes the wallet list" : "Opens the wallet list")
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
/// Gestures: tap = switch (or close the list when it is the active one),
/// pencil = rename, swipe left = delete (inactive rows only), long-press then
/// drag = reorder.
///
/// The row is a Button so a tap is a plain button tap. The reorder gesture is
/// attached as a simultaneous gesture, outermost, so it never competes with
/// the button or with the scroll view: a tap fires the action and a vertical
/// swipe scrolls the list even though a long press is armed. Once the press
/// lifts the row the parent disables scrolling; the row then follows the
/// finger through its own gesture state (only this row re-renders per frame)
/// and tells the parent about a move only when the finger crosses into
/// another slot. The release that ends a lift is swallowed (`didLift`) so it
/// never switches wallets. The delete swipe is the separate 20pt drag it has
/// always been: it reads only a horizontal-dominant end and is ignored while
/// a lift is in progress.
struct WalletRow: View {
    let wallet: WalletInfo
    let isActive: Bool
    let balance: Decimal
    let address: String?
    /// Top of one row to the top of the next (row height plus the list gap);
    /// each slot of drag moves the drop target by one.
    let slot: CGFloat
    let onTap: () -> Void
    let onRename: () -> Void
    /// nil for the active wallet: it is deleted from Settings, not by a swipe.
    let onDelete: (() -> Void)?
    /// nil when the row is already first / last.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let reorder: ReorderHandlers

    /// Reorder callbacks. `delta` is how many slots the finger has moved
    /// from where the long press fired, positive downward.
    struct ReorderHandlers {
        var onLift: () -> Void
        var onMove: (Int) -> Void
        var onDrop: (Int) -> Void
        var onCancel: () -> Void
    }

    /// The lifted row's live state. A gesture state resets when the gesture
    /// ends or the system cancels it (which `onEnded` never reports), so the
    /// `isLifted` true to false edge is the one signal that covers both.
    private struct Lift: Equatable {
        var isLifted = false
        var translation: CGFloat = 0
    }

    @State private var showDeleteZone = false
    @GestureState private var lift = Lift()
    /// Set when the press lifts the row, cleared a beat after the finger goes
    /// up: the Button action fires on that same release and must not switch.
    @State private var didLift = false
    /// True from the moment a horizontal swipe is recognised until just after
    /// it ends, so the release does not fire the row's tap.
    @State private var didSwipe = false
    /// The last slot delta the parent heard about; it hears about a move only
    /// when this changes, not on every frame.
    @State private var reportedDelta = 0

    private static let slide = Animation.snappy(duration: 0.3)

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

            Button {
                // The release that ends a drag or a swipe is not a tap.
                guard !didLift, !didSwipe else { return }
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
            // Inner: the delete swipe at normal priority, so the scroll view
            // keeps every vertical drag (a high-priority drag here took them
            // all and the list could not scroll); horizontal drags fall
            // through to it, and `didSwipe` keeps that release from tapping.
            // Outer: the reorder gesture runs alongside both and the scroll view.
            .gesture(deleteSwipe)
            .simultaneousGesture(reorderGesture)
            .accessibilityIdentifier(isActive ? "wallet.row.active" : "wallet.row")
            .accessibilityHint(isActive ? "Double tap to close the wallet list" : "Double tap to switch to this wallet")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            // VoiceOver cannot swipe the delete zone open, find the pencil
            // inside the row, or long-press drag; expose all of it as rotor
            // actions on the row itself.
            .accessibilityActions {
                Button("Rename") { onRename() }
                if let onDelete {
                    Button("Delete") { onDelete() }
                }
                if let onMoveUp {
                    Button("Move up") { onMoveUp() }
                }
                if let onMoveDown {
                    Button("Move down") { onMoveDown() }
                }
            }
            .offset(x: showDeleteZone ? -88 : 0)
        }
        .padding(.horizontal)
        // The lifted row follows the finger frame by frame with no animation
        // (isLifted does not change per frame); the lift and the settle back
        // to its slot ride the snappy spring. No shadow: one on a Liquid
        // Glass surface re-renders every frame the row moves.
        .offset(y: lift.translation)
        .scaleEffect(lift.isLifted ? 1.03 : 1)
        .animation(Self.slide, value: lift.isLifted)
        .onChange(of: lift.isLifted) { _, lifted in
            if lifted {
                liftIfNeeded()
            } else {
                // A drop already cleared the parent's state; this is a no-op
                // then and the put-back on a system cancel otherwise.
                reorder.onCancel()
                // Outlive the Button action that fires on the same release.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didLift = false }
            }
        }
    }

    /// The long press fired. Reached from the gesture's first change and from
    /// the state edge, whichever lands first; the parent hears it once, and
    /// always before the first slot move.
    private func liftIfNeeded() {
        guard !didLift else { return }
        didLift = true
        reportedDelta = 0
        withAnimation(.snappy(duration: 0.25)) { showDeleteZone = false }
        HapticFeedback.shared.buttonPress()
        reorder.onLift()
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

            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary.opacity(0.5))
                .onTapGesture { onRename() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Rename \(wallet.name)")
                .accessibilityIdentifier(isActive ? "wallet.switcher.rename" : "wallet.row.rename")

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Current wallet")
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: - Gestures

    /// Whole slots the finger has moved. Zero until the row has been
    /// measured, so an unmeasured row can never jump to the end of the list.
    private func slots(for dy: CGFloat) -> Int {
        guard slot > 20 else { return 0 }
        return Int((dy / slot).rounded())
    }

    /// Hold 0.4s, then drag. Global coordinates: the row moves with the
    /// finger, so its own space would drift under the touch.
    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($lift) { value, state, _ in
                if case .second(true, let drag) = value {
                    state = Lift(isLifted: true, translation: drag?.translation.height ?? 0)
                }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                liftIfNeeded()
                let delta = slots(for: drag?.translation.height ?? 0)
                guard delta != reportedDelta else { return }
                reportedDelta = delta
                reorder.onMove(delta)
            }
            .onEnded { value in
                guard case .second(true, let drag) = value else { return }
                reorder.onDrop(slots(for: drag?.translation.height ?? 0))
            }
    }

    /// A clear horizontal swipe reveals Delete on inactive rows. Vertical
    /// movement belongs to the scroll view, which cancels this drag when it
    /// starts to pan; a swipe that began as a lift is ignored.
    private var deleteSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard onDelete != nil, !didLift, !lift.isLifted else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    didSwipe = true
                }
            }
            .onEnded { value in
                defer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didSwipe = false }
                }
                guard onDelete != nil, !didLift, !lift.isLifted else { return }
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
struct WalletManagerRows: View {
    @Binding var isExpanded: Bool
    /// True while a row is lifted. The dashboard disables its scroll view on
    /// it so the pan cannot take the drag away from the row.
    @Binding var isReordering: Bool
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

    // Reorder state. The lifted row keeps its own live translation (see
    // WalletRow); this view knows only which row is lifted and where it
    // would land, so a finger move re-renders one row, not the list, and the
    // rows that slide aside animate on the few drop-target changes. The drop
    // reads the live list and the live target, never a value captured when
    // a row's closures were built.
    @State private var dragId: UUID?
    @State private var dropIndex: Int?
    @State private var rowHeights: [UUID: CGFloat] = [:]
    /// Keeps the dropped row above its neighbours while it settles.
    @State private var settlingId: UUID?

    private static let rowGap: CGFloat = 10
    /// The snappy spring rows slide aside and settle on.
    private static let slide = Animation.snappy(duration: 0.3)

    private var wallets: [WalletInfo] { walletManager.wallets }

    /// One slot: the lifted row's own height plus the gap.
    private var step: CGFloat {
        (dragId.flatMap { rowHeights[$0] } ?? 0) + Self.rowGap
    }

    /// How far a row that is not being dragged slides to make room.
    private func shift(for index: Int, from: Int, to target: Int) -> CGFloat {
        if index > from && index <= target { return -step }
        if index < from && index >= target { return step }
        return 0
    }

    var body: some View {
        let activeId = walletManager.activeWallet?.id
        let from = dragId.flatMap { id in wallets.firstIndex { $0.id == id } }

        VStack(spacing: Self.rowGap) {
            ForEach(Array(wallets.enumerated()), id: \.element.id) { index, wallet in
                let isActive = wallet.id == activeId
                let aside: CGFloat = {
                    guard let from, let dropIndex else { return 0 }
                    return shift(for: index, from: from, to: dropIndex)
                }()

                WalletRow(
                    wallet: wallet,
                    isActive: isActive,
                    balance: isActive ? walletManager.displayBalance : (wallet.cachedBalance ?? 0),
                    address: isActive ? walletManager.primaryAddress : wallet.cachedPrimaryAddress,
                    slot: (rowHeights[wallet.id] ?? 0) + Self.rowGap,
                    onTap: {
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
                    onMoveUp: index > 0 ? { nudge(wallet.id, by: -1) } : nil,
                    onMoveDown: index < wallets.count - 1 ? { nudge(wallet.id, by: 1) } : nil,
                    reorder: .init(
                        onLift: { lift(wallet.id) },
                        onMove: { delta in drag(wallet.id, by: delta) },
                        onDrop: { delta in drop(wallet.id, by: delta) },
                        onCancel: { cancelDrag(wallet.id) }
                    )
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[wallet.id] = $0 }
                .offset(y: aside)
                .zIndex(dragId == wallet.id || settlingId == wallet.id ? 1 : 0)
                .animation(Self.slide, value: dropIndex)
            }

            // Add Wallet button
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
        .onDisappear { isReordering = false }
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

    /// Where a row `delta` slots below its current place lands, clamped to
    /// the list.
    private func target(of id: UUID, by delta: Int) -> Int? {
        guard let from = wallets.firstIndex(where: { $0.id == id }) else { return nil }
        return min(max(from + delta, 0), wallets.count - 1)
    }

    /// The long press fired: the row is lifted and the list stops scrolling.
    private func lift(_ id: UUID) {
        dragId = id
        dropIndex = target(of: id, by: 0)
        settlingId = nil
        isReordering = true
    }

    /// The finger crossed into another slot: the rows in between slide
    /// aside and the pass ticks.
    private func drag(_ id: UUID, by delta: Int) {
        guard dragId == id, let to = target(of: id, by: delta), to != dropIndex else { return }
        dropIndex = to
        HapticFeedback.shared.softTick()
    }

    /// Commits the drop. The target and the list are read here, through the
    /// manager, not from values captured when the row was built.
    private func drop(_ id: UUID, by delta: Int) {
        guard dragId == id else { return }
        let to = target(of: id, by: delta)
        settle(id) {
            if let to {
                walletManager.moveWallet(id: id, to: to)
            }
        }
    }

    /// The system cancelled the gesture, or the drop already committed.
    private func cancelDrag(_ id: UUID) {
        guard dragId == id else { return }
        settle(id) {}
    }

    private func settle(_ id: UUID, then commit: () -> Void) {
        settlingId = id
        withAnimation(Self.slide) {
            dragId = nil
            dropIndex = nil
            commit()
        }
        isReordering = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if settlingId == id { settlingId = nil }
        }
    }

    /// VoiceOver "Move up" / "Move down": one slot, read from the live list.
    private func nudge(_ id: UUID, by delta: Int) {
        guard let to = target(of: id, by: delta) else { return }
        withAnimation(Self.slide) {
            walletManager.moveWallet(id: id, to: to)
        }
        UIAccessibility.post(notification: .announcement, argument: delta < 0 ? "Moved up" : "Moved down")
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
