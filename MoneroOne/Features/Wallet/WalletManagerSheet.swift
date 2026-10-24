import SwiftUI
import UIKit
import Metal

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
            .background(Circle().fill(Color.brand))
            .overlay(
                Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5)
            )
            .accessibilityLabel("View-only wallet")
    }
}

/// The same corner badge for a hardware wallet, with the shield the app uses
/// for hardware wallets elsewhere. A hardware wallet can send (the device
/// signs), so it gets this badge instead of the view-only eye. It marks the
/// kind of wallet only: the balance card's Live pill shows the device link.
struct HardwareAvatarBadge: View {
    var body: some View {
        Image(systemName: "lock.shield.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.brand))
            .overlay(
                Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5)
            )
            .accessibilityLabel("Hardware wallet")
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
                        Circle().strokeBorder(isActive ? Color.brand : Color.clear, lineWidth: 2)
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
                                        Circle().strokeBorder(choice == emoji ? Color.brand : Color.clear, lineWidth: 2)
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
                Text(walletManager.activeWallet?.name ?? String(localized: "Wallet"))
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

    /// The glass button's own side inset around its label at the default
    /// text size (it grows at the accessibility sizes); the fallback style
    /// has none. The handle, laid over a row, adds it to line up with its
    /// slot in the label and with the press zone.
    static var labelInset: CGFloat {
        if #available(iOS 26.0, *) { 12 } else { 0 }
    }

    /// The largest text size the row's glyphs (handle, pencil, check) grow
    /// to. Their 24pt slots sit 14pt apart and the glyphs draw past them as
    /// the text grows; past this size the pencil reaches the check.
    static let glyphSizeCap: DynamicTypeSize = .accessibility1
}

/// The inside of a wallet switcher row: the emoji circle with its kind
/// badge, the name, the orange balance and the 8…8 address, then the
/// trailing slots. The switcher and the claim sheet's wallet rows use it.
struct WalletRowContent<Trailing: View>: View {
    let wallet: WalletInfo
    /// False leaves the balance line out (the claim sheet's wallet row).
    let showsBalance: Bool
    /// The wallet's keys are not on this iPhone: "Needs restore" takes the
    /// balance line's place.
    let needsRestore: Bool
    /// Inactive wallets may not have a cached balance yet. Unknown is not zero.
    let balance: Decimal?
    let address: String?
    /// A line in the address's place (Transfer: why a wallet is dimmed).
    let note: String?
    /// Fiat Mode: the balance in fiat ("$150.23"), shown in place of XMR.
    /// nil shows XMR (Fiat Mode off, or no price yet).
    let fiatBalance: String?
    let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        wallet: WalletInfo,
        showsBalance: Bool = true,
        needsRestore: Bool = false,
        balance: Decimal?,
        address: String?,
        note: String? = nil,
        fiatBalance: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.wallet = wallet
        self.showsBalance = showsBalance
        self.needsRestore = needsRestore
        self.balance = balance
        self.address = address
        self.note = note
        self.fiatBalance = fiatBalance
        self.trailing = trailing()
    }

    /// "1.2345 XMR", "$150.23" in Fiat Mode, or "— XMR" when unknown.
    private var balanceText: String {
        if let fiatBalance, balance != nil { return fiatBalance }
        return "\(balance.map(XMRFormatter.format) ?? "—") XMR"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(wallet.emoji)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    // Hardware first: `isViewOnly` is true for it too.
                    if wallet.requiresHardwareSession {
                        HardwareAvatarBadge().offset(x: 3, y: 3)
                    } else if wallet.isViewOnly {
                        ViewOnlyAvatarBadge().offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                // One line with "…"; the accessibility sizes wrap it.
                Text(wallet.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)

                if needsRestore {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("Needs restore", comment: "Wallet switcher: the wallet's keys are not on this iPhone")
                    }
                    .font(.callout.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.brand)
                    .accessibilityIdentifier("wallet.row.needsRestore")
                } else if showsBalance {
                    WalletRowBalance(text: balanceText)
                        .foregroundStyle(balance == nil ? Color.secondary : Color.brand)
                }

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let address, !address.isEmpty {
                    // The 8…8 short form, as in the Receive rows and on Android.
                    Text(verbatim: ReceiveAddressLogic.shortAddress(address))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            // The text takes the width before the spacer does, so a short
            // line like "Needs restore" does not wrap.
            .layoutPriority(1)

            Spacer(minLength: 0)

            trailing
        }
    }
}

/// A wallet row's balance line. Every digit, always: a long balance shrinks
/// to fit, down to 60% (the balance floor), and wraps at that size when it
/// is still too wide, so no digit is ever lost to an ellipsis.
private struct WalletRowBalance: View {
    let text: String
    @ScaledMetric(relativeTo: .callout) private var calloutSize: CGFloat = 16

    private static let floor: CGFloat = 0.6

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // One line while it fits at the floor. The scale factor goes a
            // little lower than the check, so rounding never cuts a digit.
            FloorWidthLayout(scale: Self.floor) {
                Text(verbatim: text)
                    .lineLimit(1)
                    .minimumScaleFactor(Self.floor - 0.05)
            }
            Text(verbatim: text)
                .font(.system(size: calloutSize * Self.floor, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.weight(.medium))
    }
}

/// Reports its content's ideal width at `scale`, so `ViewThatFits` keeps a
/// shrinking line while it can still fit at that scale. A real width
/// passes through untouched.
private struct FloorWidthLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        guard proposal.width == nil else { return size }
        return CGSize(width: size.width * scale, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: proposal.width ?? bounds.width, height: proposal.height ?? bounds.height)
        )
    }
}

/// The switcher's mark in a row's last slot: a green check on the current
/// wallet, an empty circle on the others.
struct WalletRowCheck: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .dynamicTypeSize(...WalletRowSurface.glyphSizeCap)
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

/// One wallet row: emoji, name, orange balance, address underneath, a rename
/// pencil, and a check plus an orange ring when it is the active wallet.
///
/// The row is a Button so a tap is a plain button tap: switch, or close the
/// list when it is the active one. The pencil renames.
///
/// Reorder is driven by `WalletManagerRows`: a press on the grab handle,
/// recognised by UIKit on the enclosing scroll view, lifts the row at once
/// (see `RowGestureHost`), and the rows draw the lift and slide aside in
/// SwiftUI.
///
/// A horizontal swipe, recognised by the list (`RowGestureHost`), moves an
/// inactive row with the finger and reveals the custom Delete zone; the row
/// draws it from `isDeleteOpen` and `swipeTravel`. VoiceOver stops once
/// per wallet: the row reads the name
/// and balance, and Edit / Delete / Move up / Move down are rotor actions
/// on it.
struct WalletRow: View {
    let wallet: WalletInfo
    let isActive: Bool
    /// Inactive wallets may not have a cached balance yet. Unknown is not zero.
    let balance: Decimal?
    let address: String?
    let onTap: () -> Void
    let onRename: () -> Void
    /// nil for the active wallet: it is deleted from Edit Wallet, not by a
    /// swipe.
    let onDelete: (() -> Void)?
    /// nil when the row is already first / last.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    /// True while this row is the one being dragged.
    let isLifted: Bool
    /// The wallet's keys are not on this iPhone (device backup, Quick
    /// Start). The row says "Needs restore" in place of the balance, and a
    /// tap restores it.
    var needsRestore: Bool = false
    /// The Delete zone is open on this row. The list owns it, so one row is
    /// open at a time.
    var isDeleteOpen: Bool = false
    /// The finger's travel while a swipe on this row is live; nil on the
    /// other rows. Only `SwipeTrack` reads it, so a swipe move redraws
    /// that modifier, not the row.
    var swipeTravel: RowTravel? = nil
    /// A tap on an open row closes it.
    var onCloseDelete: () -> Void = {}
    /// Fiat Mode: the balance in fiat, shown in place of XMR.
    var fiatBalance: String? = nil

    /// The handle column, from the row's leading edge: its 16pt margin, the
    /// glass inset, the 16pt row padding, the 24pt handle and 12pt of
    /// slack, which stops short of the emoji. A press there lifts the row
    /// at once; the list hit-tests it against the row's frame.
    static var handleZoneWidth: CGFloat { 16 + WalletRowSurface.labelInset + 16 + 24 + 12 }

    /// How far an open row moves left to show Delete.
    static let deleteWidth: CGFloat = 88
    /// A flick faster than this (pt/s) opens or closes Delete at any distance.
    static let flickSpeed: CGFloat = 300
    static let settle = Animation.snappy(duration: 0.25)

    var body: some View {
        rowButton
            .modifier(SwipeTrack(travel: swipeTravel, isDeleteOpen: isDeleteOpen, onDelete: onDelete))
            .padding(.horizontal)
    }

    /// The tappable row, shared by both paths. The list swallows the
    /// release that ends a swipe or a drag before it reaches these.
    private var rowButton: some View {
        Button {
            if isDeleteOpen {
                onCloseDelete()
            } else {
                onTap()
            }
        } label: {
            rowContent
                .padding(16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .overlay {
            WalletRowSurface.ring(.brand.opacity(isActive ? 0.7 : 0))
        }
        .opacity(isActive ? 1 : 0.85)
        .accessibilityIdentifier(isActive ? "wallet.row.active" : "wallet.row")
        // Name and balance only. The merged label also read the whole
        // 95-character address on every row; the address and icon wait on
        // the More Content rotor instead.
        .accessibilityLabel(spokenLabel)
        .accessibilityCustomContent(AccessibilityCustomContentKey("Address"), address.flatMap { $0.isEmpty ? nil : Text($0) })
        .accessibilityCustomContent("Icon", wallet.emoji)
        .accessibilityHint(needsRestore ? "Double tap to restore this wallet" : isActive ? "Double tap to close the wallet list" : "Double tap to switch to this wallet")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // VoiceOver cannot swipe, long-press, drag, or tap the pencil; all
        // of it is a rotor action on the row itself. SwiftUI hands actions
        // to VoiceOver last first (same on iOS 18.5, 26.1 and 27.0), so
        // they are listed backwards to reach it as Edit, Delete, Move up,
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
            Button("Edit") { onRename() }
        }
        // After the row's accessibility modifiers, so the pencil keeps its own
        // identifier.
        .overlayPreferenceValue(PencilSlotKey.self) { slot in
            // On the pencil's slot in `rowContent`. The glass style's inset
            // grows with the text size, so the slot is read, not computed.
            GeometryReader { proxy in
                if let slot {
                    let rect = proxy[slot]
                    renameButton
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .overlay(alignment: .leading) {
            // The handle's slot in `rowContent`, after the glass inset and
            // the 16pt row padding.
            reorderHandle
                .padding(.leading, 16 + WalletRowSurface.labelInset)
        }
    }

    /// The grab handle. The list's press recognizer drags the row from here
    /// (`RowGestureHost`); the glyph only marks the spot. Hidden from
    /// VoiceOver, like the pencil: the row already has Move up / Move down
    /// on the rotor, so each wallet stays one stop.
    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.title3)
            .dynamicTypeSize(...WalletRowSurface.glyphSizeCap)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .accessibilityIdentifier("wallet.row.handle")
    }

    /// Names the last-known or unavailable balance on inactive wallets.
    /// The Selected trait marks the active wallet.
    private var spokenLabel: String {
        Self.spokenLabel(wallet: wallet, balance: balance, isActive: isActive, needsRestore: needsRestore)
    }

    /// "Savings, last known balance 0.0500 XMR, view-only". The claim
    /// sheet's wallet list reads its rows the same way.
    static func spokenLabel(wallet: WalletInfo, balance: Decimal?, isActive: Bool, needsRestore: Bool = false) -> String {
        let amount: String
        if needsRestore {
            amount = String(localized: "Needs restore", comment: "Wallet switcher: the wallet's keys are not on this iPhone")
        } else if let balance {
            amount = isActive
                ? "\(XMRFormatter.format(balance)) XMR"
                : String(localized: "last known balance \(XMRFormatter.format(balance)) XMR", comment: "VoiceOver: inactive wallet balance from its last sync")
        } else {
            amount = String(localized: "balance unavailable", comment: "VoiceOver: wallet has no previously recorded balance")
        }
        var parts = [wallet.name, amount]
        if wallet.requiresHardwareSession {
            parts.append(String(localized: "hardware wallet", comment: "VoiceOver: wallet kind after name and balance"))
        } else if wallet.isViewOnly {
            parts.append(String(localized: "view-only", comment: "VoiceOver: wallet kind after name and balance"))
        }
        return parts.joined(separator: ", ")
    }

    /// The pencil, for touch. A Button of its own so a tap on it opens Edit
    /// Wallet instead of switching. Hidden from VoiceOver: as its own element
    /// it put a stop before every wallet, and the row already has Edit as a
    /// rotor action.
    private var renameButton: some View {
        Button(action: onRename) {
            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .dynamicTypeSize(...WalletRowSurface.glyphSizeCap)
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
            // Holds the handle's place; the real handle is `reorderHandle`,
            // laid over the row outside its Button.
            Color.clear
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            WalletRowContent(wallet: wallet, needsRestore: needsRestore, balance: balance, address: address, fiatBalance: fiatBalance) {
                // Holds the pencil's place; the real pencil is `renameButton`,
                // laid over the row outside its Button so its tap renames.
                Color.clear
                    .frame(width: 24, height: 24)
                    .anchorPreference(key: PencilSlotKey.self, value: .bounds) { $0 }
                    .accessibilityHidden(true)

                WalletRowCheck(isSelected: isActive)
            }
        }
    }
}

/// The finger's travel during a reorder drag or a delete swipe. Every touch
/// writes it, and only the modifier of the one row under the finger reads
/// it (`LiftOffset`, `SwipeTrack`). As `@State` on the list it re-ran the
/// list and every glass row on each touch, which dropped frames.
@MainActor @Observable
final class RowTravel {
    /// Vertical travel of the lifted row.
    var drag: CGFloat = 0
    /// Horizontal travel of the swiped row.
    var swipe: CGFloat = 0
}

/// Where a row sits across a delete swipe, and the Delete zone it uncovers:
/// at rest, open by the Delete width, or under the finger. Past the Delete
/// width it moves at a third of the finger's pace (no full-swipe delete);
/// it never moves right of rest. The active wallet (no `onDelete`) does not
/// move: it is deleted from Edit Wallet.
private struct SwipeTrack: ViewModifier {
    /// Non-nil only on the row being swiped.
    let travel: RowTravel?
    let isDeleteOpen: Bool
    let onDelete: (() -> Void)?

    func body(content: Content) -> some View {
        let rowOffset = rowOffset
        ZStack(alignment: .trailing) {
            if rowOffset < 0, let onDelete {
                Button {
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
                .opacity(min(1, -rowOffset / WalletRow.deleteWidth))
                .transition(.opacity)
            }

            content
                .offset(x: rowOffset)
        }
    }

    private var rowOffset: CGFloat {
        guard onDelete != nil else { return 0 }
        let raw = (isDeleteOpen ? -WalletRow.deleteWidth : 0) + (travel?.swipe ?? 0)
        if raw < -WalletRow.deleteWidth {
            return -WalletRow.deleteWidth + (raw + WalletRow.deleteWidth) / 3
        }
        return min(0, raw)
    }
}

/// A row's vertical offset during a reorder: the lifted row follows the
/// finger, read here so a move redraws this modifier only; the others take
/// their slide from the list, which changes at slot crossings.
private struct LiftOffset: ViewModifier {
    let travel: RowTravel
    let isLifted: Bool
    let slide: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: isLifted ? travel.drag : slide)
    }
}

/// The pencil's placeholder in a wallet row's label, where `WalletRow`
/// lays the real pencil.
private struct PencilSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Expanded wallet manager: EVERY wallet in store order (insertion order until
/// the user drags), the active one marked in place with a check and an orange
/// ring, then Add Wallet. Inline on the dashboard, not a sheet.
///
/// A row moves by its grab handle (`RowGestureHost`) and `moveWallet`
/// persists the order; VoiceOver has Move up / Move down on every row.
struct WalletManagerRows: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showAddWallet = false
    @State private var showTransfer = false
    @State private var renameWalletId: UUID?
    @State private var renameText = ""
    @State private var renameEmoji = ""
    @State private var deleteWalletId: UUID?
    /// Confirmed in Edit Wallet: deleted once that sheet has closed.
    @State private var editDeleteWalletId: UUID?
    /// "Needs restore" seed wallet: the phrase restore cover.
    @State private var showRestoreCover = false
    @State private var restoreWalletId: UUID?
    /// "Needs restore" view-only or hardware wallet: no phrase can restore
    /// it, so the alert offers Delete and adding it again.
    @State private var readdWalletId: UUID?
    @State private var isSwitching = false
    /// Guards the destructive Delete button on the confirmation alert —
    /// rapid double-taps would invoke `deleteWallet(id:)` twice and race
    /// the in-flight `completeSwitchToWallet` teardown.
    @State private var isDeleting = false

    private static let rowGap: CGFloat = 10
    /// The snappy spring a nudged row settles on.
    private static let slide = Animation.snappy(duration: 0.3)

    // Drag to reorder. UIKit recognises the press (`RowGestureHost`),
    // SwiftUI draws it: the lifted row follows the finger through
    // `travel.drag`, the others slide aside as `dropIndex` changes.
    @State private var dragId: UUID?
    @State private var dropIndex: Int?
    /// Row frames in window space, kept current by the rows.
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// The frames when the lift began; the maths uses these, not the moving ones.
    @State private var framesAtLift: [UUID: CGRect] = [:]
    @State private var liftPoint: CGPoint = .zero
    /// The release that ends a drag reaches the row's Button; swallow it.
    @State private var suppressTapsUntil = Date.distantPast

    // Swipe to delete. UIKit recognises the pan (`RowGestureHost`), SwiftUI
    // draws it: the swiped row follows `travel.swipe`.
    @State private var swipeId: UUID?
    /// The row whose Delete zone is open; one at a time.
    @State private var openDeleteId: UUID?
    /// The finger's travel for both. The list body never reads it, so a
    /// touch move redraws only the row under the finger.
    @State private var travel = RowTravel()

    private var wallets: [WalletInfo] { walletManager.wallets }

    private var rowsStack: some View {
        VStack(spacing: Self.rowGap) {
            ForEach(wallets) { wallet in
                row(for: wallet)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[wallet.id] = $0 }
                    .modifier(LiftOffset(travel: travel, isLifted: dragId == wallet.id, slide: slideOffset(for: wallet.id)))
                    .scaleEffect(dragId == wallet.id ? 1.03 : 1)
                    .zIndex(dragId == wallet.id ? 1 : 0)
                    .animation(dragId == wallet.id ? nil : Self.slide, value: dropIndex)
                    .animation(.snappy(duration: 0.2), value: dragId)
            }

            // Transfer can send back to this wallet, so one wallet is
            // enough. A wallet that cannot send (view-only) has no Transfer,
            // and Add Wallet fills the row.
            // At the accessibility text sizes the two buttons stack, so
            // neither label is cut.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if walletManager.canSend {
                    transferButton
                }
                addWalletButton
            }
            .padding(.horizontal)
        }
        .background {
            RowGestureHost(
                isEnabled: isExpanded && !isSwitching && !walletManager.isSwitchingWallet,
                shouldBegin: { point in handleRowId(at: point) != nil },
                onBegan: lift,
                onChanged: move,
                onEnded: drop,
                onCancelled: cancelDrag,
                shouldBeginSwipe: { point in dragId == nil && rowId(at: point) != nil },
                onSwipe: swipe
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
                    .foregroundStyle(.brand)
                Text("Add Wallet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
    }

    /// Opens Transfer: Send's steps, from this wallet to another of yours or
    /// back to this one.
    private var transferButton: some View {
        Button {
            showTransfer = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.brand)
                Text("Transfer")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .glassButtonStyle()
        .accessibilityHint(Text("Moves XMR to another of your wallets, or back to this one", comment: "VoiceOver: the Transfer button in the wallet switcher"))
        .accessibilityIdentifier("wallet.switcher.transfer")
    }

    var body: some View {
        rowsStack
        .sheet(isPresented: $showTransfer) {
            SendFlowView(isTransfer: true, onTransferDone: {
                withAnimation(.snappy(duration: 0.35)) { isExpanded = false }
            })
                .environmentObject(walletManager)
                .environmentObject(priceService)
        }
        .fullScreenCover(isPresented: $showAddWallet, onDismiss: {
            walletManager.addWalletPath = []
        }) {
            AddWalletView()
        }
        .sheet(isPresented: Binding(
            get: { renameWalletId != nil },
            set: { if !$0 { renameWalletId = nil } }
        ), onDismiss: {
            guard let id = editDeleteWalletId else { return }
            editDeleteWalletId = nil
            guard !isDeleting else { return }
            isDeleting = true
            walletManager.deleteWallet(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isDeleting = false
            }
        }) {
            EditWalletSheet(
                name: $renameText,
                emoji: $renameEmoji,
                onSave: {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let id = renameWalletId, !trimmed.isEmpty {
                        walletManager.renameWallet(id: id, name: trimmed, emoji: renameEmoji)
                    }
                    renameWalletId = nil
                },
                onDelete: {
                    // Close the sheet first; `onDismiss` deletes.
                    editDeleteWalletId = renameWalletId
                    renameWalletId = nil
                }
            )
            // The Delete button must not be cut at accessibility text sizes.
            .presentationDetents([dynamicTypeSize.isAccessibilitySize ? .large : .medium])
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
        .fullScreenCover(isPresented: $showRestoreCover) {
            if let id = restoreWalletId {
                NeedsRestoreCover(walletId: id)
            }
        }
        .alert("Needs restore", isPresented: Binding(
            get: { readdWalletId != nil },
            set: { if !$0 { readdWalletId = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                readdWalletId = nil
            }
            Button("Delete", role: .destructive) {
                if let id = readdWalletId {
                    walletManager.deleteWallet(id: id)
                }
                readdWalletId = nil
            }
        } message: {
            Text("This wallet's keys are not on this iPhone. Delete it, then add it again with Add Wallet.")
        }
    }

    /// One row. The closures read the live list through the manager when
    /// they fire, never an index captured when the row was built.
    private func row(for wallet: WalletInfo) -> some View {
        let isActive = wallet.id == walletManager.activeWallet?.id
        let needsRestore = walletManager.needsRestore(wallet.id)
        let balance: Decimal? = isActive ? walletManager.displayBalance : wallet.cachedBalance
        return WalletRow(
            wallet: wallet,
            isActive: isActive,
            balance: balance,
            address: isActive ? walletManager.primaryAddress : wallet.cachedPrimaryAddress,
            onTap: {
                guard dragId == nil, Date() > suppressTapsUntil else { return }
                if needsRestore {
                    if wallet.isViewOnly {
                        readdWalletId = wallet.id
                    } else {
                        restoreWalletId = wallet.id
                        showRestoreCover = true
                    }
                } else if isActive {
                    withAnimation(.snappy(duration: 0.35)) { isExpanded = false }
                } else {
                    switchTo(wallet)
                }
            },
            onRename: {
                // A swipe or drag that ends on the pencil is not a tap.
                guard dragId == nil, Date() > suppressTapsUntil else { return }
                renameText = wallet.name
                renameEmoji = wallet.emoji
                renameWalletId = wallet.id
            },
            onDelete: isActive ? nil : {
                withAnimation(WalletRow.settle) { openDeleteId = nil }
                deleteWalletId = wallet.id
            },
            onMoveUp: wallets.first?.id == wallet.id ? nil : { nudge(wallet.id, by: -1) },
            onMoveDown: wallets.last?.id == wallet.id ? nil : { nudge(wallet.id, by: 1) },
            isLifted: dragId == wallet.id,
            needsRestore: needsRestore,
            isDeleteOpen: openDeleteId == wallet.id,
            swipeTravel: swipeId == wallet.id ? travel : nil,
            onCloseDelete: {
                guard Date() > suppressTapsUntil else { return }
                withAnimation(WalletRow.settle) { openDeleteId = nil }
            },
            // Fiat Mode, as on the Activity rows.
            fiatBalance: priceService.showFiatFirst ? balance.flatMap { priceService.formatFiatValue($0) } : nil
        )
    }

    // MARK: - Swipe to delete

    /// A horizontal swipe on a row. The row follows the finger; on release
    /// Delete stays open past half its width or after a leftward flick, and
    /// otherwise the row springs back. The swipe's release never taps the
    /// row, so it never switches the wallet.
    private func swipe(_ phase: RowGestureHost.SwipePhase) {
        switch phase {
        case .began(let point):
            let id = rowId(at: point)
            swipeId = id
            travel.swipe = 0
            suppressTapsUntil = .distantFuture
            if openDeleteId != nil, openDeleteId != id {
                withAnimation(WalletRow.settle) { openDeleteId = nil }
            }
        case .changed(let dx):
            travel.swipe = dx
        case .ended(let dx, let velocity):
            suppressTapsUntil = Date().addingTimeInterval(0.3)
            guard let id = swipeId else { return }
            let canDelete = id != walletManager.activeWallet?.id
            let end = (openDeleteId == id ? -WalletRow.deleteWidth : 0) + dx
            let open: Bool
            if velocity < -WalletRow.flickSpeed {
                open = true
            } else if velocity > WalletRow.flickSpeed {
                open = false
            } else {
                open = end < -WalletRow.deleteWidth / 2
            }
            withAnimation(WalletRow.settle) {
                openDeleteId = open && canDelete ? id : nil
                swipeId = nil
                travel.swipe = 0
            }
        case .cancelled:
            suppressTapsUntil = Date().addingTimeInterval(0.3)
            withAnimation(WalletRow.settle) {
                swipeId = nil
                travel.swipe = 0
            }
        }
    }

    // MARK: - Drag to reorder

    private func rowId(at point: CGPoint) -> UUID? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// The row whose grab handle is under `point`: the row's leading column,
    /// full height. Not on a row with Delete open, whose handle has slid away.
    private func handleRowId(at point: CGPoint) -> UUID? {
        guard let id = rowId(at: point), id != openDeleteId, let frame = rowFrames[id] else { return nil }
        return point.x < frame.minX + WalletRow.handleZoneWidth ? id : nil
    }

    /// The press began on a row: lift it. Frames are snapshotted here so the
    /// drop maths never sees the rows it is moving.
    private func lift(at point: CGPoint) {
        guard let id = rowId(at: point), let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        framesAtLift = rowFrames
        liftPoint = point
        travel.drag = 0
        dropIndex = index
        dragId = id
        suppressTapsUntil = .distantFuture
        HapticFeedback.shared.buttonPress()
    }

    private func move(to point: CGPoint) {
        guard let dragId, let frame = framesAtLift[dragId] else { return }
        travel.drag = point.y - liftPoint.y
        let centerY = frame.midY + travel.drag
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
            travel.drag = 0
            dropIndex = nil
        }
    }

    private func cancelDrag() {
        guard dragId != nil else { return }
        suppressTapsUntil = Date().addingTimeInterval(0.3)
        withAnimation(Self.slide) {
            dragId = nil
            travel.drag = 0
            dropIndex = nil
        }
    }

    /// Where each other row draws while a drag is in flight: the rows
    /// between the lifted row's old and new slot shift by one slot. The
    /// lifted row follows the finger in `LiftOffset`.
    private func slideOffset(for id: UUID) -> CGFloat {
        guard let dragId, id != dragId, let from = wallets.firstIndex(where: { $0.id == dragId }) else { return 0 }
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
        UIAccessibility.post(notification: .announcement, argument: delta < 0 ? String(localized: "Moved up") : String(localized: "Moved down"))
    }
}



/// One UIKit press recognizer on the enclosing scroll view, the way
/// UITableView reorders by its grabber. It begins only on a row's grab
/// handle, at touch down, with no hold, and stops the scroll view's pan for
/// that touch; a touch anywhere else fails it at once, so the list scrolls
/// and the delete swipe has no rival. SwiftUI gesture compositions
/// could not do this inside a ScrollView (each attempt swallowed the vertical
/// drags), the iOS 27 reorder container asserted on every lift, and system
/// drag and drop showed a copy badge. Locations are in window space, which
/// is what the rows report through `frame(in: .global)`.
///
/// The delete swipe is a UIKit pan on the same scroll view, the way
/// UITableView swipes rows. A SwiftUI drag on the row lost to the glass
/// Button's press: a swipe that started anywhere but the pencil tapped the
/// row and switched the wallet. The pan begins only when its first movement
/// is horizontal and starts on a row, so vertical drags still scroll.
private struct RowGestureHost: UIViewRepresentable {
    var isEnabled: Bool
    var shouldBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void
    /// Gets the point where the swipe's touch went down.
    var shouldBeginSwipe: (CGPoint) -> Bool
    var onSwipe: (SwipePhase) -> Void

    enum SwipePhase {
        /// The point where the touch went down, in window space.
        case began(CGPoint)
        /// Horizontal travel since the touch went down.
        case changed(CGFloat)
        /// Horizontal travel and velocity (pt/s) at the release.
        case ended(CGFloat, velocity: CGFloat)
        case cancelled
    }

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
        context.coordinator.pan.isEnabled = isEnabled
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
        var parent: RowGestureHost
        let recognizer = UILongPressGestureRecognizer()
        let pan = UIPanGestureRecognizer()
        private weak var scrollView: UIScrollView?

        init(_ parent: RowGestureHost) {
            self.parent = parent
            super.init()
            // At touch down: the handle needs no hold.
            recognizer.minimumPressDuration = 0
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.addTarget(self, action: #selector(handlePan(_:)))
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
            scroll.addGestureRecognizer(pan)
            scrollView = scroll
            Self.yieldGlassDrags(to: scroll, swipe: pan)
            Self.warmRenderer()
        }

        /// Liquid Glass buttons stretch toward a dragging finger through one
        /// recognizer UIKit keeps on the window. For about a second after
        /// the rows appear it beat the list's own pan: a flick that landed
        /// on a row did nothing, then scrolling suddenly worked (iPhone 17
        /// Pro Max, iOS 27.0). Make it wait for the scroll view's pan to
        /// fail, as content does in any scroll view; a still press never
        /// starts it, so the press feedback stays. The recognizer is private
        /// and matched by name: if it is renamed this does nothing. It waits
        /// for the delete swipe too, so a swiped row slides and does not
        /// stretch.
        private static func yieldGlassDrags(to scroll: UIScrollView, swipe: UIPanGestureRecognizer) {
            for recognizer in scroll.window?.gestureRecognizers ?? []
            where String(describing: type(of: recognizer)).contains("FlexInteraction") {
                recognizer.require(toFail: scroll.panGestureRecognizer)
                recognizer.require(toFail: swipe)
            }
        }

        /// The first stretch of a glass row under a dragging finger makes
        /// RenderBox create its Metal device and draw its first image: a
        /// 25-30 ms stall about 170 ms into the first grab after launch.
        /// The device is created off the main thread when the list opens,
        /// and one tiny image that is never shown is drawn once the list
        /// has settled. Nothing on screen changes.
        @MainActor private static var rendererWarmed = false
        @MainActor private static func warmRenderer() {
            guard !rendererWarmed else { return }
            rendererWarmed = true
            DispatchQueue.global(qos: .userInitiated).async {
                _ = MTLCreateSystemDefaultDevice()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    let warmUp = RoundedRectangle(cornerRadius: 4)
                        .fill(.black)
                        .frame(width: 8, height: 8)
                        .blur(radius: 2)
                        .shadow(radius: 2)
                    _ = ImageRenderer(content: warmUp).cgImage
                }
            }
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            pan.view?.removeGestureRecognizer(pan)
            scrollView?.isScrollEnabled = true
            frameRate.stop(after: 0)
        }

        /// Keeps the display at its top rate while a finger moves a row and
        /// while the row settles. ProMotion runs at 60 Hz while only a touch
        /// moves the row, so it followed the finger at half the rate of the
        /// slide that a slot crossing starts.
        private let frameRate = TopFrameRate()

        /// SwiftUI's own recognizer on the hosting view takes every touch
        /// down (that is the Button's pressed state) and is exclusive by
        /// default, which cancelled this press before it could begin. Run
        /// alongside it; the row swallows the tap that ends a lift.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard parent.isEnabled else { return false }
            guard gesture === pan else {
                return parent.shouldBegin(gesture.location(in: nil))
            }
            // A lifted row is being reordered; no swipe on top of it.
            guard recognizer.state != .began, recognizer.state != .changed else { return false }
            let travel = pan.translation(in: nil)
            let velocity = pan.velocity(in: nil)
            let isHorizontal = travel == .zero
                ? abs(velocity.x) > abs(velocity.y)
                : abs(travel.x) > abs(travel.y)
            return isHorizontal && parent.shouldBeginSwipe(touchDownPoint)
        }

        /// Where the pan's touch went down: its location less its travel.
        private var touchDownPoint: CGPoint {
            let location = pan.location(in: nil)
            let travel = pan.translation(in: nil)
            return CGPoint(x: location.x - travel.x, y: location.y - travel.y)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let dx = gesture.translation(in: nil).x
            switch gesture.state {
            case .began:
                // Hold the list still for the rest of this touch.
                scrollView?.isScrollEnabled = false
                frameRate.start()
                parent.onSwipe(.began(touchDownPoint))
                parent.onSwipe(.changed(dx))
            case .changed:
                parent.onSwipe(.changed(dx))
            case .ended:
                scrollView?.isScrollEnabled = true
                parent.onSwipe(.ended(dx, velocity: gesture.velocity(in: nil).x))
                frameRate.stop(after: TopFrameRate.settleTime)
            case .cancelled, .failed:
                scrollView?.isScrollEnabled = true
                parent.onSwipe(.cancelled)
                frameRate.stop(after: TopFrameRate.settleTime)
            default:
                break
            }
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                // Kill the pan for the rest of this touch; re-enabled on release.
                frameRate.start()
                scrollView?.isScrollEnabled = false
                parent.onBegan(point)
            case .changed:
                parent.onChanged(point)
            case .ended:
                scrollView?.isScrollEnabled = true
                parent.onEnded(point)
                frameRate.stop(after: TopFrameRate.settleTime)
            case .cancelled, .failed:
                scrollView?.isScrollEnabled = true
                parent.onCancelled()
                frameRate.stop(after: TopFrameRate.settleTime)
            default:
                break
            }
        }
    }
}

/// A display link that asks for the display's top rate while it runs. It
/// draws nothing: only its rate request counts.
@MainActor
private final class TopFrameRate: NSObject {
    /// The drop and the swipe settle are 0.25-0.3 s springs; the rate holds
    /// a little past them.
    static let settleTime: TimeInterval = 0.4
    private var link: CADisplayLink?

    func start() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(end), object: nil)
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(end), object: nil)
        perform(#selector(end), with: nil, afterDelay: delay, inModes: [.common])
    }

    @objc private func end() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
    }
}

/// Edit Wallet: the name, the emoji picker circle, and Delete Wallet last,
/// for every wallet (a swipe deletes only inactive ones).
struct EditWalletSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let onSave: () -> Void
    /// Confirmed: the caller closes the sheet, then deletes the wallet.
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var isDeleting = false

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

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("Delete Wallet")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("wallet.edit.delete")
            }
            .navigationTitle("Edit Wallet")
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
        // The swipe's alert, here so it opens over this sheet.
        .alert("Delete Wallet?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard !isDeleting else { return }
                isDeleting = true
                onDelete()
            }
            .disabled(isDeleting)
        } message: {
            Text("This removes the wallet from this device. You can recover it with the seed phrase.")
        }
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
