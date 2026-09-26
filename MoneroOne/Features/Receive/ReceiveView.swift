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
    /// One height for the action buttons' icons, so their titles line up:
    /// the plus is shorter than the other two.
    @ScaledMetric(relativeTo: .title3) private var actionIconHeight: CGFloat = 24

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
        ScrollView {
            VStack(spacing: 24) {
                Text("Receive XMR")
                    .font(.title2)
                    .fontWeight(.bold)
                    .qrFocusRecede(focus, toward: .top)

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
                    .shadow(color: .black.opacity(0.1), radius: 10)
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

                // Selected Address Card - Tap to change
                NavigationLink {
                    AddressPickerView()
                } label: {
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(addressLabel)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)

                                CodeText(formatAddress(currentAddress))
                            }

                            Spacer()

                            VStack(spacing: 2) {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if rotateReceiveAddress {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                Text("New address after each payment")
                                    .font(.caption2)
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if selectedAddressIndex == 0 {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text("Main address links all transactions. Use subaddresses for privacy.")
                                    .font(.caption2)
                            }
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Privacy warning: Main address links all transactions. Use subaddresses for privacy.")
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("\(addressLabel), \(formatAddress(currentAddress))\(rotateReceiveAddress ? String(localized: ", new address after each payment") : "")")
                .accessibilityHint("Opens address picker to change receiving address")
                .padding(.horizontal)
                .qrFocusRecede(focus, toward: .bottom)

                // Action Buttons
                HStack(spacing: 16) {
                    // Copy Button
                    Button {
                        copyAddress()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.title3)
                                .frame(height: actionIconHeight)
                            Text(copied ? "Copied!" : "Copy")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(copied ? Color.green : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityIdentifier("receive.copyButton")
                    .accessibilityLabel(copied ? "Address copied" : "Copy address")
                    .accessibilityHint("Copies the Monero address to clipboard")

                    // Share Button
                    Button {
                        showShareSheet = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3)
                                .frame(height: actionIconHeight)
                            Text("Share")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .accessibilityLabel("Share address")
                    .accessibilityHint("Opens share sheet with QR code and address")

                    // New Address Button
                    Button {
                        createNewAddress()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.title3)
                                .frame(height: actionIconHeight)
                                .opacity(isCreating ? 0 : 1)
                                .overlay {
                                    if isCreating {
                                        ProgressView()
                                    }
                                }
                            Text("New")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .glassButtonStyle()
                    .disabled(isCreating || !canCreateAddress)
                    .accessibilityIdentifier("receive.newButton")
                    .accessibilityLabel(isCreating
                        ? Text("Creating subaddress")
                        : Text("New address", comment: "VoiceOver: the Receive screen's New button"))
                    .accessibilityHint("Creates a new subaddress for receiving Monero")
                }
                .padding(.horizontal)
                .disabled(currentAddress.isEmpty || currentAddress == "Loading..." || keysUnavailable)
                .qrFocusRecede(focus, toward: .bottom)

                if let note = ReceiveAddressLogic.limitText(creationLimit) {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .qrFocusRecede(focus, toward: .bottom)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 24)
        }
    }

    private func formatAddress(_ addr: String) -> String {
        // "Loading..." is a sentinel inside currentAddress; translate it only here.
        if addr == "Loading..." { return String(localized: "Loading...") }
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(12))...\(addr.suffix(8))"
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

struct AddressPickerView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) var dismiss
    @State private var isCreating = false
    @State private var showCreateError = false
    @State private var renameIndex: Int? = nil
    @State private var renameText: String = ""
    @State private var renameEmoji: String = ""

    /// The index Receive shows, kept per wallet by the manager.
    private var selectedIndex: Int { walletManager.selectedReceiveIndex }

    /// How far New may go before a seed restore would miss payments.
    private var creationLimit: ReceiveAddressLogic.CreationLimit {
        ReceiveAddressLogic.creationLimit(
            subaddresses: walletManager.subaddresses.map(SubaddressSummary.init),
            transactions: walletManager.transactions
        )
    }

    /// Subaddress creation only needs the wallet pointer (key derivation), not daemon sync
    private var canCreateSubaddress: Bool {
        guard !walletManager.primaryAddress.isEmpty else { return false }
        if case .stop = creationLimit { return false }
        return true
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Main Address Card
                AddressCard(
                    label: String(localized: "Main Address"),
                    address: walletManager.primaryAddress,
                    index: 0,
                    isSelected: selectedIndex == 0,
                    showWarning: true
                ) {
                    walletManager.noteManualReceiveSelection(index: 0)
                    dismiss()
                }

                // Section Header for Subaddresses
                HStack {
                    Text("Subaddresses")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        createNewSubaddress()
                    } label: {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Label("New", systemImage: "plus")
                                .font(.subheadline)
                        }
                    }
                    .disabled(isCreating || !canCreateSubaddress)
                    .accessibilityLabel(isCreating ? "Creating subaddress" : "Create new subaddress")
                    .accessibilityHint("Creates a new subaddress for receiving Monero")
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                if let note = ReceiveAddressLogic.limitText(creationLimit) {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                // Show all subaddresses except index 0 (main address shown above)
                let actualSubaddresses = walletManager.subaddresses.filter {
                    $0.index > 0 && !$0.address.isEmpty
                }

                if actualSubaddresses.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No subaddresses yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Create subaddresses for better privacy when receiving payments.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(actualSubaddresses, id: \.index) { subaddr in
                        let displayLabel = SubaddressName.display(index: subaddr.index, label: subaddr.label)
                        AddressCard(
                            label: displayLabel,
                            address: subaddr.address,
                            index: subaddr.index,
                            isSelected: selectedIndex == subaddr.index,
                            showWarning: false,
                            onSelect: {
                                walletManager.noteManualReceiveSelection(index: subaddr.index)
                                dismiss()
                            },
                            onRename: {
                                let parts = splitSubaddressLabel(subaddr.label)
                                renameEmoji = parts.emoji
                                renameText = parts.name
                                renameIndex = subaddr.index
                            }
                        )
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Select Address")
        .navigationBarTitleDisplayMode(.inline)
        .horizontalBarsOnDuo()
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

    private func createNewSubaddress() {
        isCreating = true

        Task {
            var result = await walletManager.createSubaddress()

            // Retry once after short delay — wallet2 C++ can fail transiently after node switch
            if result == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                result = await walletManager.createSubaddress()
            }

            await MainActor.run {
                isCreating = false

                if result != nil {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                } else {
                    showCreateError = true
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Address Card (Liquid Glass Style)

struct AddressCard: View {
    let label: String
    let address: String
    let index: Int
    let isSelected: Bool
    let showWarning: Bool
    let onSelect: () -> Void
    var onRename: (() -> Void)? = nil

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            if index == 0 {
                                Text("Primary")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .cornerRadius(4)
                            }
                        }

                        CodeText(formatAddress(address))
                    }

                    Spacer()

                    if let onRename {
                        Button(action: onRename) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename \(label)")
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }

                if showWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("Links all transactions together")
                            .font(.caption2)
                    }
                    .foregroundColor(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(isSelected ? Color.green.opacity(0.5) : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(AddressCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(isSelected ? String(localized: "selected") : String(localized: "not selected"))\(showWarning ? String(localized: ", warning: links all transactions together") : "")")
        .accessibilityHint("Double tap to select this address")
    }

    private func formatAddress(_ addr: String) -> String {
        guard addr.count > 24 else { return addr }
        return "\(addr.prefix(16))...\(addr.suffix(8))"
    }
}

// MARK: - Custom Button Style

struct AddressCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
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
