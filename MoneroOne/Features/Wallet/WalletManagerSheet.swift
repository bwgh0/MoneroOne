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

    @State private var isActive = false

    var body: some View {
        ZStack {
            Text(emoji)
                .font(.system(size: fontSize))
                .frame(width: size, height: size)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(isActive ? Color.orange : Color.clear, lineWidth: 2)
                )
                .onTapGesture { isActive = true }

            EmojiTextFieldRepresentable(emoji: $emoji, isActive: $isActive)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
    }
}

struct WalletSwitcherButton: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject var walletManager: WalletManager
    @State private var showRenameActive = false
    @State private var renameText = ""
    @State private var renameEmoji = ""

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.35)) {
                isExpanded.toggle()
            }
        } label: {
            if isExpanded {
                expandedLabel
            } else {
                collapsedLabel
            }
        }
        .glassButtonStyle()
        .sheet(isPresented: $showRenameActive) {
            RenameWalletSheet(
                name: $renameText,
                emoji: $renameEmoji,
                onSave: {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let id = walletManager.activeWallet?.id, !trimmed.isEmpty {
                        walletManager.renameWallet(id: id, name: trimmed, emoji: renameEmoji)
                    }
                }
            )
            .presentationDetents([.medium])
        }
    }

    // MARK: - Collapsed

    private var collapsedLabel: some View {
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

    // MARK: - Expanded (current wallet card)

    private var truncatedAddress: String {
        let addr = walletManager.primaryAddress
        guard addr.count > 16 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(8))"
    }

    private var expandedLabel: some View {
        HStack(spacing: 14) {
            Text(walletManager.activeWallet?.emoji ?? "\u{1F4B0}")
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if walletManager.isViewOnly {
                        ViewOnlyAvatarBadge().offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(walletManager.activeWallet?.name ?? "Wallet")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 0) {
                    Text(XMRFormatter.format(walletManager.balance))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                    Text(" XMR")
                        .layoutPriority(1)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)

                Text(truncatedAddress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer()

            // Rename pencil for active wallet
            Image(systemName: "pencil.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary.opacity(0.5))
                .onTapGesture {
                    renameText = walletManager.activeWallet?.name ?? ""
                    renameEmoji = walletManager.activeWallet?.emoji ?? "\u{1F4B0}"
                    showRenameActive = true
                }

            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

/// A single inactive wallet row with swipe-to-delete and inline rename
struct WalletRow: View {
    let wallet: WalletInfo
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteZone = false

    private var truncated: String {
        let addr = wallet.cachedPrimaryAddress ?? ""
        guard addr.count > 16 else { return addr }
        return "\(addr.prefix(8))...\(addr.suffix(8))"
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if showDeleteZone {
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

            Button { onTap() } label: {
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
                            Text(XMRFormatter.format(wallet.cachedBalance ?? 0))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(0)
                            Text(" XMR")
                                .layoutPriority(1)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)

                        if !truncated.isEmpty {
                            Text(truncated)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }
                    }

                    Spacer()

                    // Rename pencil
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary.opacity(0.5))
                        .onTapGesture { onRename() }

                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .glassButtonStyle()
            .opacity(0.85)
            .offset(x: showDeleteZone ? -88 : 0)
        }
        .padding(.horizontal)
        .highPriorityGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    withAnimation(.snappy(duration: 0.25)) {
                        if value.translation.width < -40 {
                            showDeleteZone = true
                        } else if value.translation.width > 20 {
                            showDeleteZone = false
                        }
                    }
                }
        )
    }
}

/// Additional wallet rows that appear when wallet manager is expanded
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

    private var otherWallets: [WalletInfo] {
        walletManager.wallets.filter { $0.id != walletManager.activeWallet?.id }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(otherWallets) { wallet in
                WalletRow(
                    wallet: wallet,
                    onTap: {
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
                    },
                    onRename: {
                        renameText = wallet.name
                        renameEmoji = wallet.emoji
                        renameWalletId = wallet.id
                    },
                    onDelete: {
                        deleteWalletId = wallet.id
                    }
                )
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
        .sheet(isPresented: $showAddWallet) {
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
}

/// Sheet for renaming a wallet with a tappable emoji picker circle
struct RenameWalletSheet: View {
    @Binding var name: String
    @Binding var emoji: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                EmojiPickerCircle(emoji: $emoji)
                    .padding(.top, 8)

                Text("Tap to change icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Wallet Name", text: $name)
                    .font(.subheadline)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("Rename Wallet")
            .navigationBarTitleDisplayMode(.inline)
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
    }
}

#Preview {
    @Previewable @State var expanded = false
    VStack {
        HStack(spacing: 0) {
            if !expanded {
                Text("Good evening")
                    .font(.title2.weight(.semibold))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Spacer(minLength: 12)
            }
            WalletSwitcherButton(isExpanded: $expanded)
                .environmentObject(WalletManager())
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        .animation(.snappy(duration: 0.35), value: expanded)
        .padding()
        Spacer()
    }
}
