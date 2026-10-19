import SwiftUI

struct SendAddressStep: View {
    /// The text of the field: an address or an OpenAlias name.
    @Binding var recipientInput: String
    @Binding var showScanner: Bool
    /// A payment link (Features/PaymentLinks) is the recipient instead of
    /// an address. The typed address stays, so ✕ on the token brings it back.
    @Binding var isLinkMode: Bool
    let isConnected: Bool
    let isValidAddress: Bool
    /// One of your wallets, when the field holds its saved primary address.
    var matchedWallet: WalletInfo? = nil
    /// The contact whose address or OpenAlias name is in the field. A
    /// wallet match wins.
    var matchedContact: Contact? = nil
    /// Contacts whose name or destination holds the typed text.
    var contactMatches: [Contact] = []
    /// The Contacts button at the end of the empty field.
    var onShowContacts: () -> Void = {}
    /// A tap on a contact under the field.
    var onPickContact: (Contact) -> Void = { _ in }
    @ObservedObject var lookup: OpenAliasLookupModel
    /// Called with the summary when the field holds a resolved name, else nil.
    let onContinue: (OpenAliasSummary?) -> Void

    @State private var showContent = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dialog: ContinueDialog?
    @FocusState private var fieldFocused: Bool
    /// Set by the card's clear button: the field that comes back gets the cursor.
    @State private var focusFieldOnAppear = false

    /// The dialog that Continue shows on a resolved name (spec 5.2).
    private enum ContinueDialog {
        case changed(OpenAliasSummary, pinnedAt: Date)
        case unsigned(OpenAliasSummary)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if !isConnected {
                        ErrorBanner(
                            message: String(localized: "No internet connection. Cannot send."),
                            type: .offline
                        )
                        .accessibilityLabel("Offline: no internet connection")
                    }

                    recipient

                    // While the field has text, Scan QR, Paste and Link step
                    // aside, and the matching contacts show.
                    if showsActionButtons {
                        actionButtons
                    } else if !contactMatches.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(contactMatches) { contact in
                                ContactRowButton(contact: contact) { onPickContact(contact) }
                            }
                        }
                    }
                }
                // Only the recipient changes: the field and the token
                // cross-fade in place.
                .animation(.easeInOut(duration: 0.35), value: isLinkMode)
                .padding()
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
            }

            // Continue button
            Button(action: continueTapped) {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(canContinue ? .brand : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .disabled(!canContinue)
            .padding()
            .accessibilityLabel("Continue")
            .accessibilityHint(continueHint)
        }
        .navigationTitle("Send XMR")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                showContent = true
            }
        }
        .alert(
            dialogTitle,
            isPresented: Binding(
                get: { dialog != nil },
                set: { if !$0 { dialog = nil } }
            ),
            presenting: dialog
        ) { dialog in
            Button("Cancel", role: .cancel) {}
            switch dialog {
            case .changed(let summary, _):
                Button("Use New Address") { onContinue(summary) }
            case .unsigned(let summary):
                Button("Continue Anyway") { onContinue(summary) }
            }
        } message: { dialog in
            switch dialog {
            case .changed(let summary, let pinnedAt):
                let paidOn = DateFormatter.localizedString(from: pinnedAt, dateStyle: .medium, timeStyle: .none)
                if let recipientName = summary.recipientName {
                    Text("The address for \(recipientName) (\(summary.name.display)) is different from the address you paid on \(paidOn). Check the new address with the recipient.",
                         comment: "Address Changed dialog: the record name, the OpenAlias name, then the date of the last payment")
                } else {
                    Text("The address for \(summary.name.display) is different from the address you paid on \(paidOn). Check the new address with the recipient.")
                }
            case .unsigned(let summary):
                Text("\(summary.name.display) has no DNSSEC signature. A DNS server between you and the owner of the name can change this answer. Check the address with the recipient before you send.")
            }
        }
    }

    /// The text field, with the lookup spinner and the clear button.
    private var fieldRow: some View {
        HStack {
            // Typed text goes to the lookup from the binding: when
            // two keystrokes land in one frame, SwiftUI drops an
            // onChange call, and the lookup kept a part of the name.
            TextField("Name, address or OpenAlias", text: Binding(
                get: { recipientInput },
                set: { newValue in
                    recipientInput = newValue
                    lookup.textChanged(newValue)
                }
            ))
                .font(.system(.caption, design: .monospaced))
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit { lookup.submit(recipientInput) }
                .accessibilityIdentifier("send.addressField")
                .accessibilityLabel("Recipient name, address or OpenAlias")

            if isLookingUpName {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Looking up \(lookup.name?.display ?? "")…"))
                    .transition(.opacity)
            }

            if !recipientInput.isEmpty {
                Button {
                    lookup.cancel()
                    recipientInput = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                // Gray like the clear button of the recipient card, which
                // takes its place: the tint made it a pale orange.
                .buttonStyle(.plain)
                .accessibilityLabel("Clear address")
            } else {
                // The clear button takes its place while the field has text.
                Button(action: onShowContacts) {
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .foregroundStyle(.brand)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-8)
                .accessibilityLabel("Contacts")
                .accessibilityIdentifier("send.contactsButton")
            }
        }
        .onAppear {
            guard focusFieldOnAppear else { return }
            focusFieldOnAppear = false
            fieldFocused = true
        }
    }

    private var isLookingUpName: Bool {
        guard case .name = input else { return false }
        return lookup.isLooking
    }

    /// The card's clear button: the empty field comes back, with the cursor.
    private func clearRecipient() {
        lookup.cancel()
        focusFieldOnAppear = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            recipientInput = ""
        }
    }

    /// The existing "Valid address" / "Invalid address" row.
    private func validationRow(isValid: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isValid ? .green : .red)
            Text(isValid ? "Valid address" : "Invalid address")
                .font(.caption)
                .foregroundStyle(isValid ? .green : .red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isValid ? "Valid address" : "Invalid address")
    }

    private var input: RecipientInput {
        OpenAlias.classify(recipientInput)
    }

    /// The lookup result, when it belongs to the name in the field.
    private var resolvedSummary: OpenAliasSummary? {
        guard case .name(let name) = input, let summary = lookup.summary,
              summary.name.query == name.query else { return nil }
        return summary
    }

    /// The "Recipient" label over the address field, or over the link token.
    private var recipient: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipient")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ZStack {
                if isLinkMode {
                    PaymentLinkRecipientToken {
                        isLinkMode = false
                    }
                    .transition(.opacity)
                } else {
                    addressField
                        .transition(.opacity)
                }
            }
        }
    }

    /// The address field. A resolved name turns it into the recipient
    /// card, inside the same rounded field.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let matchedWallet {
                    WalletRecipientCard(
                        wallet: matchedWallet,
                        address: recipientInput.trimmingCharacters(in: .whitespacesAndNewlines),
                        onClear: clearRecipient
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .transition(.opacity)
                } else if let matchedContact {
                    ContactRecipientCard(contact: matchedContact, onClear: clearRecipient, onOpenContacts: onShowContacts)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .transition(.opacity)
                } else if let resolvedSummary {
                    OpenAliasRecipientCard(summary: resolvedSummary, onClear: clearRecipient)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .transition(.opacity)
                } else {
                    fieldRow
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            // The link token has the same height, so the buttons stay put.
            .frame(minHeight: 54)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            // Validation indicator. On the name path the lookup
            // row takes its place, in a slot of the same height. The
            // matching contacts take its place while they show.
            if !recipientInput.isEmpty, showsActionButtons || contactMatches.isEmpty {
                ZStack(alignment: .leading) {
                    validationRow(isValid: false)
                        .hidden()
                        .accessibilityHidden(true)
                    switch input {
                    case .empty:
                        EmptyView()
                    case .address:
                        // Typed text shows its row after the typing delay.
                        if lookup.phase == .address {
                            validationRow(isValid: isValidAddress)
                                .transition(.opacity)
                        }
                    case .name, .reserved, .invalidName:
                        if let resolvedSummary {
                            OpenAliasResolvedLines(summary: resolvedSummary)
                                .transition(.opacity)
                        } else {
                            OpenAliasStatusRow(lookup: lookup)
                        }
                    }
                }
            }
        }
    }

    /// Scan QR, Paste and Link: the three ways to fill the recipient. They
    /// stack at accessibility text sizes, or when a label would not fit.
    private var actionButtons: some View {
        RecipientButtonsLayout(alwaysStacks: dynamicTypeSize.isAccessibilitySize) {
            Button {
                showScanner = true
            } label: {
                actionLabel("Scan QR", systemImage: "qrcode.viewfinder")
            }
            .glassButtonStyle()
            .accessibilityLabel("Scan QR code")

            Button {
                if let clipboard = UIPasteboard.general.string {
                    isLinkMode = false
                    recipientInput = clipboard
                    lookup.submit(clipboard)
                }
            } label: {
                actionLabel("Paste", systemImage: "doc.on.clipboard")
            }
            .glassButtonStyle()
            .accessibilityLabel("Paste address from clipboard")

            Button {
                isLinkMode = true
            } label: {
                actionLabel("Link", systemImage: "link", isOn: !isLinkMode)
            }
            .glassButtonStyle()
            .disabled(isLinkMode)
            .accessibilityLabel("Link")
            .accessibilityHint("Sends the money as a link anyone can claim")
            .accessibilityAddTraits(isLinkMode ? .isSelected : [])
            .accessibilityIdentifier("send.linkButton")
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, isOn: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(isOn ? .brand : .gray)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// Scan QR, Paste and Link: with an empty field, a link, or a card.
    private var showsActionButtons: Bool {
        isLinkMode || recipientInput.isEmpty || matchedWallet != nil || matchedContact != nil || resolvedSummary != nil
    }

    /// A link needs no address: it can go on as soon as Send can.
    private var canContinue: Bool {
        guard isConnected else { return false }
        if isLinkMode { return true }
        switch input {
        case .address: return isValidAddress
        case .name: return resolvedSummary != nil
        case .empty, .reserved, .invalidName: return false
        }
    }

    private var continueHint: Text {
        if canContinue || isLinkMode { return Text("Proceed to enter amount") }
        if case .name = input, lookup.isLooking { return Text("Wait for the name lookup to finish") }
        return Text("Enter a valid address first")
    }

    private var dialogTitle: Text {
        switch dialog {
        case .changed: return Text("Address Changed")
        case .unsigned: return Text("Name Not Signed")
        case nil: return Text(verbatim: "")
        }
    }

    /// Continue on a resolved name shows one dialog at most: a changed pin
    /// first, since its message also asks for a check, then a name with no
    /// DNSSEC signature.
    private func continueTapped() {
        guard !isLinkMode, case .name = input else {
            onContinue(nil)
            return
        }
        guard let summary = resolvedSummary else { return }
        if case .changed(let pinnedAt) = summary.pin {
            dialog = .changed(summary, pinnedAt: pinnedAt)
        } else if summary.dnssec == .off {
            dialog = .unsigned(summary)
        } else {
            onContinue(summary)
        }
    }
}

/// Equal capsules in one row with a 12 gutter, or one column when the
/// widest label does not fit its share of the row.
private struct RecipientButtonsLayout: Layout {
    var alwaysStacks = false
    var spacing: CGFloat = 12

    private func itemWidth(in width: CGFloat, count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    private func fitsInRow(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard !alwaysStacks, subviews.count > 1 else { return false }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let width else { return true }
        return widest <= itemWidth(in: width, count: subviews.count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        if fitsInRow(proposal.width, subviews) {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let width = proposal.width ?? widest * count + spacing * (count - 1)
            let item = itemWidth(in: width, count: subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: item, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * (count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if fitsInRow(bounds.width, subviews) {
            let item = itemWidth(in: bounds.width, count: subviews.count)
            var x = bounds.minX
            for subview in subviews {
                // Centered like an HStack: the Paste glyph runs a little taller.
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: item, height: nil))
                x += item + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }
}

/// One of your wallets in the recipient field: its emoji, name and 8…8
/// address, as the wallet switcher shows it, with the clear button.
struct WalletRecipientCard: View {
    let wallet: WalletInfo
    let address: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(wallet.emoji)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: ReceiveAddressLogic.shortAddress(address))
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    // A 44 pt target around the glyph, which keeps its place.
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-12)
            .accessibilityLabel("Clear address")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(wallet.name), \(ReceiveAddressLogic.shortAddress(address))"))
        .accessibilityAction(named: Text("Clear address"), onClear)
        .accessibilityIdentifier("send.walletCard")
    }
}
