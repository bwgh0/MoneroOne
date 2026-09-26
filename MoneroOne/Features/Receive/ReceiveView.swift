import MoneroKit
import SwiftUI

struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var requestAmount = ""
    @State private var requestFiatAmount = ""
    @State private var isFiatMode = false
    @State private var showShareSheet = false
    @State private var isCreating = false
    @State private var showCreateError = false
    /// New Address's result until the kit lists it (one main-queue hop
    /// later), so the card never shows the main address in between.
    @State private var created: MoneroKit.SubAddress?
    @AppStorage(WalletManager.rotateReceiveAddressKey) private var rotateReceiveAddress: Bool = true
    @EnvironmentObject var priceService: PriceService

    /// The index Receive shows, kept per wallet by the manager.
    private var selectedAddressIndex: Int { walletManager.selectedReceiveIndex }

    /// The subaddress at `index`: the kit's entry, else New Address's
    /// result while the kit has not listed it yet.
    private func subaddress(at index: Int) -> MoneroKit.SubAddress? {
        if let listed = walletManager.subaddresses.first(where: { $0.index == index && !$0.address.isEmpty }) {
            return listed
        }
        if let created, created.index == index {
            return created
        }
        return nil
    }

    /// Computes the effective address index, falling back to 0 if selected subaddress doesn't exist
    /// This avoids race conditions by not modifying state during view computation
    private var effectiveAddressIndex: Int {
        if selectedAddressIndex == 0 {
            return 0
        } else if subaddress(at: selectedAddressIndex) != nil {
            return selectedAddressIndex
        } else {
            // Subaddress doesn't exist (wallet changed or new wallet) - use primary
            return 0
        }
    }

    /// True when the wallet's keys did not load — the address the runtime
    /// would render is the null-key burn address (no private key exists for
    /// it). The screen must show an error instead of anything QR-shaped.
    private var keysUnavailable: Bool {
        if NullKeyAddress.isNullKey(walletManager.primaryAddress) { return true }
        if case .error = walletManager.syncState, walletManager.primaryAddress.isEmpty { return true }
        return false
    }

    private var currentAddress: String {
        // Never render the null-key address, whatever path produced it.
        guard !keysUnavailable else { return "" }
        if effectiveAddressIndex == 0 {
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
        } else {
            if let subaddr = subaddress(at: effectiveAddressIndex),
               !NullKeyAddress.isNullKey(subaddr.address) {
                return subaddr.address
            }
            return walletManager.primaryAddress.isEmpty ? "Loading..." : walletManager.primaryAddress
        }
    }

    /// The same name the transaction screens give this address: its label,
    /// else "Subaddress #index".
    private var addressLabel: String {
        SubaddressName.display(
            index: effectiveAddressIndex,
            in: walletManager.subaddresses.map(SubaddressSummary.init)
        )
    }

    /// The request amount as a number. Comma-decimal regions type "1,5" on
    /// the decimal pad, and `Decimal(string: "1,5")` reads 1: the QR code
    /// would ask for less than the user typed.
    private var requestedXMR: Decimal? {
        Decimal(string: requestAmount.replacingOccurrences(of: ",", with: "."))
    }

    /// The fiat request amount as a number; `Double("1,5")` is nil.
    private var requestedFiat: Double? {
        Double(requestFiatAmount.replacingOccurrences(of: ",", with: "."))
    }

    private var qrContent: String {
        let addr = currentAddress
        if addr.isEmpty || addr == "Loading..." { return "" }
        if let amount = requestedXMR, amount > 0 {
            return "monero:\(addr)?tx_amount=\(amount)"
        }
        // A monero: URI rather than the bare address, so the Camera app and
        // other wallets offer to open it. Copy still copies the bare address.
        return "monero:\(addr)"
    }

    /// Writes the QR to the photo library (add-only permission, prompted on
    /// first use). Success and failure are both announced for VoiceOver.
    private func saveQRToPhotos() {
        guard let image = QRCodeRenderer.renderToImage(content: qrContent) else { return }
        UIImageWriteToSavedPhotosAlbum(
            image,
            PhotoSaveResponder.shared,
            #selector(PhotoSaveResponder.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private var shareItems: [Any] {
        var items: [Any] = []

        // Generate QR code image
        if let qrImage = QRCodeRenderer.renderToImage(content: qrContent) {
            items.append(qrImage)
        }

        // Create share message
        var message = String(localized: "Send me Monero (XMR) at this address:\n\n\(currentAddress)")
        if let amount = requestedXMR, amount > 0 {
            message = String(localized: "Send me \(requestAmount) XMR at this address:\n\n\(currentAddress)")
        }
        items.append(message)

        return items
    }

    var body: some View {
        NavigationStack {
            // Inside the stack: the code grows from its place into focus
            // mode, and both have to share one hosting view.
            QRFocusContainer { focus in
                content(focus: focus)
            }
            // An inline title like Send's, so the code, the amount, the
            // address block and its footer fit above Copy and Share.
            .navigationTitle("Receive XMR")
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .alert("Couldn't Create Address", isPresented: $showCreateError) {
                Button("OK") {}
            } message: {
                Text("Please wait until the wallet finishes syncing and try again.")
            }
            .onAppear {
                walletManager.reconcileReceiveAddress()
                // Rotation off: reset to the main address if the selected
                // subaddress doesn't exist. With rotation on the manager
                // owns the index; it may point at an address the kit has
                // not listed yet, and resetting it here would undo that.
                if !rotateReceiveAddress && selectedAddressIndex > 0 &&
                   !walletManager.subaddresses.contains(where: { $0.index == selectedAddressIndex && !$0.address.isEmpty }) {
                    walletManager.setReceiveSelection(0)
                }
            }
        }
    }

    private func content(focus: QRFocus) -> some View {
        // Copy and Share stay under the scrolling content, 16pt above the
        // home indicator, like Continue in Send.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    // QR Code
                    if keysUnavailable {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .font(.largeTitle)
                                .foregroundColor(.red)
                            Text("Wallet keys unavailable")
                                .font(.headline)
                            Text("The wallet couldn't load its keys, so no receive address can be shown. Do not send funds to any address from this app until this is resolved. Force-quit and reopen the app; if this persists, restore the wallet from its seed.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .frame(width: 280, height: 280)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(20)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Wallet keys unavailable. No receive address can be shown.")
                    } else if !currentAddress.isEmpty && currentAddress != "Loading..." {
                        // A tap grows the code into focus mode.
                        FocusableQRPlate(
                            item: QRFocusItem(
                                content: qrContent,
                                title: addressLabel,
                                // The same lenient read as the code: "1,5" is 1.5.
                                amount: requestedXMR.flatMap { $0 > 0 ? $0 : nil }
                            ),
                            side: 280,
                            focus: focus,
                            label: String(localized: "QR code for receiving Monero")
                        )
                        // A new address (New, or rotation after a
                        // payment) cross-fades the code in place.
                        .animation(.easeInOut(duration: 0.25), value: currentAddress)
                        .contextMenu {
                            Button {
                                saveQRToPhotos()
                            } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                            if let image = QRCodeRenderer.renderToImage(content: qrContent) {
                                ShareLink(
                                    item: Image(uiImage: image),
                                    preview: SharePreview("Monero receive QR code", image: Image(uiImage: image))
                                ) {
                                    Label("Share QR Code", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        // After the plate's own accessibility element:
                        // set before it, the id sat on an ignored child
                        // and UI tests could not find the code.
                        .accessibilityIdentifier("receive.qrCode")
                        .accessibilityHint("Shows the code full screen. Actions available: save to Photos, or share")
                        .accessibilityAction(named: "Save to Photos") {
                            saveQRToPhotos()
                        }
                    } else {
                        Rectangle()
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 280, height: 280)
                            .cornerRadius(20)
                            .overlay {
                                ProgressView()
                            }
                    }

                    // Request Amount (Optional)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request Amount (optional)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Spacer()

                            if priceService.xmrPrice != nil {
                                Button {
                                    toggleReceiveFiatMode()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down")
                                            .font(.caption2.weight(.semibold))
                                        Text(isFiatMode ? "XMR" : priceService.selectedCurrency.uppercased())
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                                .accessibilityLabel("Switch between XMR and \(priceService.selectedCurrency.uppercased()) input")
                            }
                        }

                        HStack {
                            if isFiatMode {
                                Text(priceService.currencySymbol)
                                    .foregroundColor(.secondary)
                                TextField("0.00", text: $requestFiatAmount)
                                    .font(.system(.body, design: .rounded))
                                    .keyboardType(.decimalPad)
                                    .accessibilityLabel("Request amount in \(priceService.selectedCurrency.uppercased())")
                                    .onChange(of: requestFiatAmount) { _ in
                                        syncReceiveXMRFromFiat()
                                    }
                            } else {
                                TextField("0.0", text: $requestAmount)
                                    .font(.system(.body, design: .rounded))
                                    .keyboardType(.decimalPad)
                                    .accessibilityLabel("Request amount in XMR")
                                    .accessibilityHint("Enter an optional amount to embed in the QR code")

                                Text("XMR")
                                    .foregroundColor(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                        // Show converted amount
                        if isFiatMode {
                            if !requestAmount.isEmpty, let amt = requestedXMR, amt > 0 {
                                Text("≈ \(requestAmount) XMR")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                            }
                        } else if let amt = requestedXMR, amt > 0,
                                  let fiat = priceService.formatFiatValue(amt) {
                            Text("≈ \(fiat)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)
                    .qrFocusRecede(focus, toward: .bottom)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil
                                )
                            }
                        }
                    }

                    addressBlock(focus: focus)
                }
                .padding(.top, 24)
                .padding(.bottom, 8)
            }

            actionButtons
                .qrFocusRecede(focus, toward: .bottom)
        }
    }

    /// The address the code shows and New Address under it, one grouped
    /// block like a Settings section; what happens next is its footer.
    private func addressBlock(focus: QRFocus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                // Selected Address - Tap to change
                NavigationLink {
                    AddressPickerView()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(addressLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(verbatim: shortCurrentAddress)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        if hasAddress {
                            AddressUsageSummary(usage: currentUsage)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(addressRowSpokenLabel)
                .accessibilityHint("Opens address picker to change receiving address")

                Divider()
                    .padding(.leading, 16)

                Button(action: createNewAddress) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.body)
                        Text("New Address", comment: "Creates a new subaddress and shows it")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCreating || !canCreateAddress)
                .opacity(canCreateAddress || isCreating ? 1 : 0.4)
                .accessibilityIdentifier("receive.newButton")
                .accessibilityLabel(isCreating
                    ? Text("Creating subaddress")
                    : Text("New Address", comment: "Creates a new subaddress and shows it"))
                .accessibilityHint("Creates a new subaddress for receiving Monero")
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            // Footer: what happens next.
            VStack(alignment: .leading, spacing: 4) {
                if selectedAddressIndex == 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Main address links all transactions. Use subaddresses for privacy.")
                    }
                    .foregroundColor(.orange)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Privacy warning: Main address links all transactions. Use subaddresses for privacy.")
                }

                if rotateReceiveAddress {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("New address after each payment")
                    }
                    .foregroundColor(.secondary)
                }

                if let note = ReceiveAddressLogic.limitText(creationLimit) {
                    Text(note)
                        .foregroundColor(.orange)
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
        }
        .padding(.horizontal)
        .qrFocusRecede(focus, toward: .bottom)
    }

    /// Copy and Share: the dashboard's pair of glass buttons.
    private var actionButtons: some View {
        let unavailable = !hasAddress || keysUnavailable
        return HStack(spacing: 12) {
            CompactActionButton(
                title: copied ? LocalizedStringResource("Copied!") : LocalizedStringResource("Copy"),
                icon: copied ? "checkmark.circle.fill" : "doc.on.doc",
                color: copied ? .green : .primary,
                isDisabled: unavailable,
                action: copyAddress
            )
            .accessibilityIdentifier("receive.copyButton")
            .accessibilityLabel(copied ? "Address copied" : "Copy address")
            .accessibilityHint("Copies the Monero address to clipboard")

            CompactActionButton(
                title: "Share",
                icon: "square.and.arrow.up",
                color: .orange,
                isDisabled: unavailable
            ) {
                showShareSheet = true
            }
            .accessibilityLabel("Share address")
            .accessibilityHint("Opens share sheet with QR code and address")
        }
        .padding()
    }

    /// True once there is a real address to show.
    private var hasAddress: Bool {
        !currentAddress.isEmpty && currentAddress != "Loading..."
    }

    /// The address row's second line: the first and last eight characters.
    private var shortCurrentAddress: String {
        // "Loading..." is a sentinel inside currentAddress; translate it only here.
        if currentAddress == "Loading..." { return String(localized: "Loading...") }
        return ReceiveAddressLogic.shortAddress(currentAddress)
    }

    private func toggleReceiveFiatMode() {
        isFiatMode.toggle()
        if isFiatMode {
            // Sync fiat from current XMR
            if let price = priceService.xmrPrice,
               let xmr = requestedXMR.map({ NSDecimalNumber(decimal: $0).doubleValue }), xmr > 0 {
                let fiat = xmr * price
                requestFiatAmount = String(format: "%.2f", fiat)
            } else {
                requestFiatAmount = ""
            }
        }
        HapticFeedback.shared.softTick()
    }

    private func syncReceiveXMRFromFiat() {
        // Same guard as the send side: a bad price here makes the payment
        // request ask for the wrong amount of XMR (under-collecting if the
        // price is inflated), and the QR encodes it.
        guard let price = priceService.xmrPrice,
              PriceService.isPlausiblePrice(price),
              let fiat = requestedFiat, fiat > 0 else {
            requestAmount = ""
            return
        }
        let xmr = fiat / price
        var s = String(format: "%.12f", xmr)
        // Trim trailing zeros
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        requestAmount = s
    }

    private func copyAddress() {
        guard !currentAddress.isEmpty, currentAddress != "Loading...", !keysUnavailable else { return }
        UIPasteboard.general.string = currentAddress
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    /// How far New may go before a seed restore would miss payments.
    private var creationLimit: ReceiveAddressLogic.CreationLimit {
        ReceiveAddressLogic.creationLimit(
            subaddresses: walletManager.subaddresses.map(SubaddressSummary.init),
            transactions: walletManager.transactions
        )
    }

    /// What the shown address has taken in.
    private var currentUsage: ReceiveAddressUsage {
        ReceiveAddressLogic.usage(of: currentAddress, transactions: walletManager.transactions)
    }

    /// The address row for VoiceOver: name, what it has taken in, and
    /// rotation.
    private var addressRowSpokenLabel: String {
        var spoken = [addressLabel]
        if hasAddress {
            spoken.append(ReceiveAddressLogic.spokenUsage(currentUsage))
        }
        return spoken.joined(separator: ", ")
            + (rotateReceiveAddress ? String(localized: ", new address after each payment") : "")
    }

    /// New needs only the wallet's keys, not a synced wallet.
    private var canCreateAddress: Bool {
        guard !keysUnavailable, !walletManager.primaryAddress.isEmpty else { return false }
        if case .stop = creationLimit { return false }
        return true
    }

    /// New: derives the next subaddress and shows it here, until it gets
    /// paid. The manager retries once; a second failure says so.
    private func createNewAddress() {
        guard !isCreating, canCreateAddress else { return }
        isCreating = true

        Task {
            let result = await walletManager.createAndSelectSubaddress { new in
                created = new
            }
            isCreating = false

            guard let result else {
                showCreateError = true
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                return
            }
            copied = false
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            let name = SubaddressName.display(index: result.index, label: result.label)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Showing new address, \(name)", comment: "VoiceOver: announced after New Address")
            )
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Address Picker View

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

/// Select Address: the wallet's addresses as a Settings-style grouped list.
/// The main address has its own section; subaddresses follow newest first
/// under New Address, every one on its own row. A tap shows that address on
/// Receive; swipe or long-press to copy or rename. Edit puts a pencil on
/// each subaddress, and a tap then renames it.
struct AddressPickerView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var isCreating = false
    @State private var showCreateError = false
    @State private var renameIndex: Int? = nil
    @State private var renameText: String = ""
    @State private var renameEmoji: String = ""
    /// Edit mode: a tap on a subaddress renames it instead of showing it.
    @State private var isEditing = false

    /// The index Receive shows, kept per wallet by the manager.
    private var selectedIndex: Int { walletManager.selectedReceiveIndex }

    var body: some View {
        let usage = ReceiveAddressLogic.usage(transactions: walletManager.transactions)
        let rows = ReceiveAddressLogic.subaddressRows(
            walletManager.subaddresses.map(SubaddressSummary.init),
            usage: usage
        )
        let limit = ReceiveAddressLogic.creationLimit(
            unusedAfterLastUsed: ReceiveAddressLogic.unusedAfterLastUsed(rows)
        )
        List {
            if let main = ReceiveAddressLogic.mainRow(primaryAddress: walletManager.primaryAddress, usage: usage) {
                Section {
                    addressRow(main)
                } footer: {
                    Text("Payments to your main address can be linked together.", comment: "Select Address: footer under the main address")
                }
            }

            Section {
                newAddressRow(canCreate: canCreate(limit))
                ForEach(rows) { row in
                    addressRow(row)
                }
            } header: {
                Text("Subaddresses")
            } footer: {
                if let note = ReceiveAddressLogic.limitText(limit) {
                    Text(note)
                } else if rows.isEmpty {
                    Text("Create subaddresses for better privacy when receiving payments.")
                }
            }
        }
        .listStyle(.insetGrouped)
        // New Address and a kit update slide rows in instead of popping them.
        .animation(.snappy(duration: 0.3), value: rows.count)
        .navigationTitle("Select Address")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { isEditing.toggle() }
                } label: {
                    isEditing
                        ? Text("Done")
                        : Text("Edit", comment: "Select Address: puts a pencil on each subaddress so a tap renames it")
                }
                .disabled(rows.isEmpty && !isEditing)
            }
        }
        .alert("Couldn't Create Address", isPresented: $showCreateError) {
            Button("OK") {}
        } message: {
            Text("Please wait until the wallet finishes syncing and try again.")
        }
        .sheet(isPresented: Binding(
            get: { renameIndex != nil },
            set: { if !$0 { renameIndex = nil } }
        )) {
            RenameSubaddressSheet(
                name: $renameText,
                emoji: $renameEmoji,
                onSave: {
                    if let idx = renameIndex {
                        let packed = joinSubaddressLabel(emoji: renameEmoji, name: renameText)
                        if walletManager.setSubaddressLabel(index: idx, label: packed),
                           !packed.isEmpty, idx == selectedIndex,
                           !walletManager.isManualReceiveSelection(index: idx) {
                            // A name reserves the address, and rotation
                            // moves past reserved ones. Naming the address
                            // Receive shows keeps it there until it gets
                            // paid instead.
                            walletManager.noteManualReceiveSelection(index: idx)
                        }
                    }
                    renameIndex = nil
                },
                onCancel: { renameIndex = nil }
            )
            .presentationDetents([.medium])
        }
    }

    /// Subaddress creation only needs the wallet pointer (key derivation),
    /// not daemon sync; it stops before a seed restore would miss payments.
    private func canCreate(_ limit: ReceiveAddressLogic.CreationLimit) -> Bool {
        guard !walletManager.primaryAddress.isEmpty else { return false }
        if case .stop = limit { return false }
        return true
    }

    // MARK: Rows

    /// One address. A tap shows it on Receive, or in edit mode renames it;
    /// swipe or long-press to copy it or rename it (subaddresses only).
    private func addressRow(_ row: ReceiveAddressRow) -> some View {
        let renames = isEditing && !row.isMain
        return Button {
            if renames {
                beginRename(row)
            } else {
                select(row.index)
            }
        } label: {
            AddressListRow(row: row, isSelected: row.index == selectedIndex, isEditing: isEditing)
        }
        // The main address has no name to edit.
        .disabled(isEditing && row.isMain)
        .opacity(isEditing && row.isMain ? 0.4 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                copy(row)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            .tint(.gray)
            if !row.isMain {
                Button {
                    beginRename(row)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                copy(row)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            if !row.isMain {
                Button {
                    beginRename(row)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .accessibilityLabel(ReceiveAddressLogic.spokenRow(row))
        .accessibilityHint(renames
            ? Text("Double tap to rename this address", comment: "VoiceOver hint: a subaddress in Select Address edit mode")
            : Text("Double tap to select this address"))
        .accessibilityAddTraits(row.index == selectedIndex ? .isSelected : [])
    }

    /// The first row of Subaddresses, its plus in the checkmark column.
    private func newAddressRow(canCreate: Bool) -> some View {
        Button(action: createNewSubaddress) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .frame(width: 20)
                Text("New Address", comment: "Creates a new subaddress and shows it")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .foregroundColor(.orange)
            .contentShape(Rectangle())
        }
        .disabled(isCreating || !canCreate || isEditing)
        .opacity((canCreate && !isEditing) || isCreating ? 1 : 0.4)
        .accessibilityIdentifier("addresses.newButton")
        .accessibilityLabel(isCreating
            ? Text("Creating subaddress")
            : Text("New Address", comment: "Creates a new subaddress and shows it"))
        .accessibilityHint("Creates a new subaddress for receiving Monero")
    }

    // MARK: Actions

    /// Shows `index` on Receive and goes back to it.
    private func select(_ index: Int) {
        walletManager.noteManualReceiveSelection(index: index)
        dismiss()
    }

    private func copy(_ row: ReceiveAddressRow) {
        UIPasteboard.general.string = row.address
        HapticFeedback.shared.softTick()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Address copied"))
    }

    private func beginRename(_ row: ReceiveAddressRow) {
        let parts = splitSubaddressLabel(row.label)
        renameEmoji = parts.emoji
        renameText = parts.name
        renameIndex = row.index
    }

    /// New Address: derives the next subaddress and selects it; the new
    /// row slides in at the top of the section with the check on it.
    private func createNewSubaddress() {
        guard !isCreating else { return }
        isCreating = true

        Task {
            let result = await walletManager.createAndSelectSubaddress()
            isCreating = false

            guard let result else {
                showCreateError = true
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
                return
            }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            let name = SubaddressName.display(index: result.index, label: result.label)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Showing new address, \(name)", comment: "VoiceOver: announced after New Address")
            )
        }
    }
}

// MARK: - Address Row

/// One address in Select Address: a check on the one Receive shows (in edit
/// mode, a pencil on each subaddress), the name (and its number when it has
/// a label), the first and last eight characters, and what the address has
/// taken in.
struct AddressListRow: View {
    let row: ReceiveAddressRow
    let isSelected: Bool
    var isEditing = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: "checkmark")
                    .opacity(isSelected && !isEditing ? 1 : 0)
                Image(systemName: "pencil")
                    .opacity(isEditing && !row.isMain ? 1 : 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.orange)
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if row.isLabeled && !row.isMain {
                        Text(verbatim: "#\(row.index)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }
                Text(verbatim: ReceiveAddressLogic.shortAddress(row.address))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            AddressUsageSummary(usage: row.usage)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Address Usage

/// What an address has taken in, on the trailing side of its row: the
/// total in green over the number of payments, or Unused.
struct AddressUsageSummary: View {
    let usage: ReceiveAddressUsage

    var body: some View {
        if usage.payments > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(XMRFormatter.formatCompact(usage.received)) XMR")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundColor(.green)
                Text(ReceiveAddressLogic.paymentCount(usage.payments))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        } else {
            Text("Unused", comment: "Address list: an address with no payments yet")
                .font(.caption)
                .foregroundColor(Color(.tertiaryLabel))
                .fixedSize()
        }
    }
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

#Preview {
    ReceiveView()
        .environmentObject(WalletManager())
        .environmentObject(PriceService())
}


/// Completion target for `UIImageWriteToSavedPhotosAlbum`: the C-style
/// callback needs an Objective-C selector on a long-lived object.
final class PhotoSaveResponder: NSObject {
    static let shared = PhotoSaveResponder()

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        if error == nil {
            HapticFeedback.shared.softTick()
            UIAccessibility.post(notification: .announcement, argument: String(localized: "QR code saved to Photos"))
        } else {
            HapticFeedback.shared.error()
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Couldn't save the QR code. Allow Photos access in Settings."))
        }
    }
}
