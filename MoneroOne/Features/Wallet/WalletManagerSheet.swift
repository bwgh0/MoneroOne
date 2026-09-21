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
/// chip while the list is open (an orange ring marks the open state); the
/// active wallet keeps its own slot in the list below instead of being pulled
/// up into the chip, so the list never reshuffles on a switch.
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
        .overlay {
            WalletRowSurface.ring(.orange.opacity(isExpanded ? 0.7 : 0))
        }
        .animation(.snappy(duration: 0.35), value: isExpanded)
        .accessibilityIdentifier("wallet.switcher")
        .accessibilityHint(isExpanded ? "Closes the wallet list" : "Opens the wallet list")
    }
}

/// The outline `.glassButtonStyle()` draws: a capsule under Liquid Glass, the
/// 12pt rounded rectangle of the fallback style. Rings drawn with it sit on
/// the glass edge instead of a guessed inset.
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
/// drag = reorder. The reorder and delete gestures live on the label, inside
/// the button, so a plain tap still reaches the button and a vertical swipe
/// still reaches the scroll view: the long press fails after 10pt of movement,
/// the delete swipe needs 20pt, and the scroll view claims the touch first.
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
    let reorder: ReorderHandlers

    /// Reorder callbacks. The vertical translation is the finger's, relative
    /// to where the long press fired.
    struct ReorderHandlers {
        var onDrag: (CGFloat) -> Void
        var onDrop: (CGFloat) -> Void
        var onCancel: () -> Void
    }

    private enum ReorderDrag: Equatable {
        case idle
        case lifted
    }

    @State private var showDeleteZone = false
    /// Mirrors the reorder gesture's phase. A gesture state resets when the
    /// system cancels the gesture, which `onEnded` never reports, so the
    /// `.lifted → .idle` edge is what tells the list to put the row back.
    @GestureState private var reorderDrag: ReorderDrag = .idle

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
                    .gesture(rowGesture)
            }
            .glassButtonStyle()
            .overlay {
                WalletRowSurface.ring(.orange.opacity(isActive ? 0.7 : 0))
            }
            .opacity(isActive ? 1 : 0.85)
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
        .onChange(of: reorderDrag) { _, phase in
            switch phase {
            case .lifted:
                withAnimation(.snappy(duration: 0.25)) { showDeleteZone = false }
            case .idle:
                reorder.onCancel()
            }
        }
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

    /// Long-press then drag reorders; a clear horizontal swipe reveals Delete.
    /// The two are exclusive with reorder first: the swipe only runs once the
    /// long press has failed, so a held finger never opens the delete zone.
    private var rowGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .exclusively(before: DragGesture(minimumDistance: 20))
            .updating($reorderDrag) { value, state, _ in
                if case .first(.second(true, _)) = value {
                    state = .lifted
                }
            }
            .onChanged { value in
                if case .first(.second(true, let drag)) = value {
                    reorder.onDrag(drag?.translation.height ?? 0)
                }
            }
            .onEnded { value in
                switch value {
                case .first(.second(true, let drag)):
                    reorder.onDrop(drag?.translation.height ?? 0)
                case .second(let swipe):
                    guard onDelete != nil else { return }
                    let dx = swipe.translation.width
                    guard abs(dx) > abs(swipe.translation.height) else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        if dx < -40 {
                            showDeleteZone = true
                        } else if dx > 20 {
                            showDeleteZone = false
                        }
                    }
                default:
                    break
                }
            }
    }
}

/// Expanded wallet manager: EVERY wallet in store order (insertion order until
/// the user drags), the active one marked in place with a check and an orange
/// ring, then Add Wallet. Inline on the dashboard, not a sheet.
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

    // Reorder state: the lifted row follows the finger, the rows it passes
    // slide aside by one step, the drop persists the new order. All of it is
    // view state so the drop reads the live list and offset, never a value
    // captured when a row's closures were built.
    @State private var dragId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragTarget: Int?
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

    private func dropTarget(from: Int) -> Int {
        guard step > Self.rowGap, !wallets.isEmpty else { return from }
        let moved = Int((dragOffset / step).rounded())
        return min(max(from + moved, 0), wallets.count - 1)
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
        let target = from.map(dropTarget(from:))

        VStack(spacing: Self.rowGap) {
            ForEach(Array(wallets.enumerated()), id: \.element.id) { index, wallet in
                let isActive = wallet.id == activeId
                let isLifted = dragId == wallet.id
                let offset: CGFloat = {
                    if isLifted { return dragOffset }
                    guard let from, let target else { return 0 }
                    return shift(for: index, from: from, to: target)
                }()

                WalletRow(
                    wallet: wallet,
                    isActive: isActive,
                    balance: isActive ? walletManager.displayBalance : (wallet.cachedBalance ?? 0),
                    address: isActive ? walletManager.primaryAddress : wallet.cachedPrimaryAddress,
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
                    onMoveUp: index > 0 ? { move(wallet.id, by: -1) } : nil,
                    onMoveDown: index < wallets.count - 1 ? { move(wallet.id, by: 1) } : nil,
                    reorder: .init(
                        onDrag: { dy in drag(wallet.id, to: dy) },
                        onDrop: { dy in drop(wallet.id, at: dy) },
                        onCancel: { cancelDrag(wallet.id) }
                    )
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[wallet.id] = $0 }
                .offset(y: offset)
                .scaleEffect(isLifted ? 1.02 : 1)
                .shadow(color: .black.opacity(isLifted ? 0.18 : 0), radius: isLifted ? 14 : 0, y: isLifted ? 6 : 0)
                .zIndex(isLifted || settlingId == wallet.id ? 1 : 0)
                .animation(isLifted ? nil : Self.slide, value: offset)
                .animation(Self.slide, value: isLifted)
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
        guard !isSwitching else { return }
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

    /// First call after the long press lifts the row (haptic, scale, shadow);
    /// every call moves it with the finger and ticks when it passes a row.
    private func drag(_ id: UUID, to dy: CGFloat) {
        if dragId != id {
            dragId = id
            dragTarget = nil
            HapticFeedback.shared.buttonPress()
        }
        dragOffset = dy
        if let from = wallets.firstIndex(where: { $0.id == id }) {
            let target = dropTarget(from: from)
            if let previous = dragTarget, previous != target {
                HapticFeedback.shared.softTick()
            }
            dragTarget = target
        }
    }

    /// Commits the drop. The target and the list are read here, through
    /// state and the manager, not from values captured when the row was built.
    private func drop(_ id: UUID, at dy: CGFloat) {
        guard dragId == id else { return }
        dragOffset = dy
        let list = walletManager.wallets
        let to = list.firstIndex(where: { $0.id == id }).map(dropTarget(from:))
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
            dragOffset = 0
            dragTarget = nil
            commit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if settlingId == id { settlingId = nil }
        }
    }

    /// VoiceOver "Move up" / "Move down": one slot, read from the live list.
    private func move(_ id: UUID, by delta: Int) {
        guard let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        let to = index + delta
        guard wallets.indices.contains(to) else { return }
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
