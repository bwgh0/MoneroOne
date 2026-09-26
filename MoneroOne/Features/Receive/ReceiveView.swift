import MoneroKit
import SwiftUI

/// Receive: one address card (name, QR, the whole address, and what
/// happens after the next payment), the optional request amount, and Copy
/// and Share. New Address derives a subaddress in place. On iPhone the
/// card's name fans every address out as cards over the screen; on iPad and
/// the unfolded Duo the cards sit beside it.
struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var priceService: PriceService
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WalletManager.rotateReceiveAddressKey) private var rotateReceiveAddress: Bool = true

    /// The index Receive shows, kept per wallet by the manager.
    private var selectedAddressIndex: Int { walletManager.selectedReceiveIndex }

    @State private var copied = false
    @State private var requestAmount = ""
    @State private var requestFiatAmount = ""
    @State private var isFiatMode = false
    @State private var showShareSheet = false
    /// iPhone: the address cards are fanned out over Receive.
    @State private var showsStack = false
    @State private var isCreating = false
    @State private var creationFailed = false
    /// New Address's result, shown until the kit lists it.
    @State private var created: ReceiveAddressRow?
    /// The index the card shows. It follows `selectedAddressIndex` one
    /// beat later, so each change animates the way its cause calls for.
    @State private var displayedIndex: Int?
    @State private var nextSwap: Swap = .rotation
    @State private var faceTransition: AnyTransition = .opacity
    @State private var isSquat = false
    @State private var showsRequestField = false
    @State private var loadTimedOut = false
    @State private var loadAttempt = 0
    @State private var width: CGFloat = 0
    @AccessibilityFocusState private var cardInfoFocused: Bool

    /// Why the shown address is about to change. Every change happens in
    /// place: nothing slides sideways, so nothing suggests a swipe.
    private enum Swap {
        /// New Address: the new card settles in where the old one was.
        case newAddress
        /// A pick among the address cards: the code cross-fades.
        case pick
        /// Rotation after a payment, or anything else: cross-fade.
        case rotation
    }

    /// Two columns (card | amount, buttons, list) from this width: iPad
    /// sheets and the unfolded Duo.
    private static let twoColumnWidth: CGFloat = 600
    private var isTwoColumn: Bool { width >= Self.twoColumnWidth }

    /// True when the wallet's keys did not load — the address the runtime
    /// would render is the null-key burn address (no private key exists for
    /// it). The screen must show an error instead of anything QR-shaped.
    private var keysUnavailable: Bool {
        if NullKeyAddress.isNullKey(walletManager.primaryAddress) { return true }
        if case .error = walletManager.syncState, walletManager.primaryAddress.isEmpty { return true }
        return false
    }

    // MARK: Model

    /// Everything the screen reads from the wallet, worked out once per
    /// render.
    private struct Snapshot {
        /// Subaddresses, newest first, with New Address's result on top
        /// until the kit lists it.
        let rows: [ReceiveAddressRow]
        let mainRow: ReceiveAddressRow?
        /// What the card shows; nil while the wallet has no address yet.
        let shown: ReceiveAddressRow?
        let limit: ReceiveAddressLogic.CreationLimit
    }

    private var snapshot: Snapshot {
        let usage = ReceiveAddressLogic.usage(transactions: walletManager.transactions)
        var rows = ReceiveAddressLogic.subaddressRows(
            walletManager.subaddresses.map(SubaddressSummary.init),
            usage: usage
        )
        if let created, !rows.contains(where: { $0.index == created.index }) {
            rows.insert(created, at: 0)
        }
        let main = keysUnavailable
            ? nil
            : ReceiveAddressLogic.mainRow(primaryAddress: walletManager.primaryAddress, usage: usage)
        let index = displayedIndex ?? selectedAddressIndex
        var shown: ReceiveAddressRow?
        if !keysUnavailable {
            if index == 0 {
                shown = main
            } else if let row = rows.first(where: { $0.index == index }) {
                shown = row
            }
            // Otherwise an index the kit has not listed yet: the card waits
            // rather than flash the main address and its warning.
        }
        let limit = ReceiveAddressLogic.creationLimit(
            unusedAfterLastUsed: ReceiveAddressLogic.unusedAfterLastUsed(rows)
        )
        return Snapshot(rows: rows, mainRow: main, shown: shown, limit: limit)
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

    private func qrContent(for row: ReceiveAddressRow?) -> String {
        guard let row else { return "" }
        if let amount = requestedXMR, amount > 0 {
            return "monero:\(row.address)?tx_amount=\(amount)"
        }
        // A monero: URI rather than the bare address, so the Camera app and
        // other wallets offer to open it. Copy still copies the bare address.
        return "monero:\(row.address)"
    }

    private func canCreate(_ s: Snapshot) -> Bool {
        guard !keysUnavailable, !walletManager.primaryAddress.isEmpty else { return false }
        if case .stop = s.limit { return false }
        return true
    }

    /// Side of the QR plate: as large as a column allows, 272pt at most,
    /// 176pt on short screens (the Duo cover then fits the card, its
    /// buttons and the amount pill without scrolling).
    private var plateSide: CGFloat {
        if isTwoColumn {
            let column = (width - 16 * 3) / 2
            return max(180, min(272, column - 48))
        }
        if isSquat { return 176 }
        return max(180, min(272, width - 32 - 48))
    }

    // MARK: Body

    var body: some View {
        let s = snapshot
        NavigationStack {
            // Inside the stack: the code grows from the card into focus
            // mode, and both have to share one hosting view.
            QRFocusContainer { focus in
                if isTwoColumn {
                    twoColumns(s, focus: focus)
                } else {
                    oneColumn(s, focus: focus)
                }
            }
            .navigationTitle(showsStack
                ? String(localized: "Addresses", comment: "Title of the receiving address list")
                : String(localized: "Receive"))
            .navigationBarTitleDisplayMode(.inline)
            .horizontalBarsOnDuo()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showsStack {
                        Button(action: closeStack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .fontWeight(.semibold)
                                Text("Receive")
                            }
                        }
                        .accessibilityLabel(String(localized: "Back to Receive", comment: "VoiceOver: closes the address cards without changing the address"))
                        .accessibilityIdentifier("receive.stack.back")
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                if showsStack {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: createAddress) {
                            if isCreating {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                        }
                        .disabled(!canCreate(s) || isCreating)
                        .accessibilityLabel(String(localized: "New address", comment: "VoiceOver: the Receive card's New button"))
                        .accessibilityIdentifier("addresses.newButton")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        endEditing()
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .detectSquatScreen($isSquat)
        .receiveSheetSizing()
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems(for: s.shown))
        }
        .onAppear {
            displayedIndex = selectedAddressIndex
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
        .onChange(of: selectedAddressIndex) { old, new in
            showSelection(from: old, to: new)
        }
        .onChange(of: isTwoColumn) { _, twoColumns in
            // Unfolding the Duo with the cards fanned out: they now sit
            // beside the Receive card instead.
            if twoColumns { showsStack = false }
        }
        .task(id: "\(s.shown == nil)-\(loadAttempt)") {
            // A card still waiting after 15 seconds says so and offers a
            // retry, instead of spinning forever.
            guard s.shown == nil, !keysUnavailable else {
                loadTimedOut = false
                return
            }
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { loadTimedOut = true }
        }
    }

    // MARK: Layouts

    /// Short screens keep Copy and Share inside the card, so the card and
    /// its actions fit without scrolling; the amount pill follows. The
    /// address cards wait above it all, closed, until the name opens them:
    /// Receive then steps back and fades while they fan in.
    private func oneColumn(_ s: Snapshot, focus: QRFocus) -> some View {
        let steppedBack = showsStack && !reduceMotion
        return ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: isSquat ? 12 : 24) {
                    card(s, focus: focus, onShowAddresses: openStack, footer: isSquat ? AnyView(actionButtons(s)) : nil)
                    Group {
                        requestSection
                        if !isSquat {
                            actionButtons(s)
                        }
                    }
                    .qrFocusRecede(focus, toward: .bottom)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, isSquat ? 12 : 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .scaleEffect(steppedBack ? 0.92 : 1, anchor: .top)
            .offset(y: steppedBack ? -24 : 0)
            .animation(stackAnimation, value: showsStack)
            .opacity(showsStack ? 0 : 1)
            .animation(receiveFade, value: showsStack)
            .allowsHitTesting(!showsStack)
            .accessibilityHidden(showsStack)

            addressCards(s, layout: .stack(isOpen: showsStack))
        }
    }

    /// The step-back and fan-in share one spring; Reduce Motion fades.
    private var stackAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)
    }

    /// Receive fades out at once as the cards fan in, and back in a beat
    /// after they close, so a picked card is seen rising into it.
    private var receiveFade: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return showsStack ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.3).delay(0.15)
    }

    /// iPad and the unfolded Duo: the card on the left; the amount, the
    /// buttons and the list on the right, so no push is needed. On the Duo
    /// the 16pt gutter lands on the fold.
    private func twoColumns(_ s: Snapshot, focus: QRFocus) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                card(s, focus: focus, onShowAddresses: nil)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            VStack(spacing: 16) {
                requestSection
                actionButtons(s)
                addressCards(s, layout: .column)
            }
            .frame(maxWidth: .infinity)
            .qrFocusRecede(focus, toward: .bottom)
        }
        .padding(16)
    }

    // MARK: Card

    private struct StatusLine {
        let text: String
        let tone: ReceiveStatusTone
    }

    private func statusLine(_ s: Snapshot) -> StatusLine {
        if creationFailed {
            return StatusLine(
                text: String(localized: "Couldn't create an address. Try again.", comment: "Receive card: New Address failed"),
                tone: .error
            )
        }
        guard let row = s.shown else {
            if keysUnavailable {
                return StatusLine(text: String(localized: "No receive address can be shown.", comment: "Receive card: the wallet's keys did not load"), tone: .error)
            }
            if loadTimedOut {
                return StatusLine(
                    text: String(localized: "The wallet hasn't opened yet.", comment: "Receive card: still no address after 15 seconds"),
                    tone: .warning
                )
            }
            return StatusLine(text: String(localized: "Opening the wallet…", comment: "Receive card: waiting for the address"), tone: .used)
        }
        if row.isMain {
            // The card's own New pill is the way out; a second button here
            // would make this card taller than the others and move what is
            // below it.
            return StatusLine(text: ReceiveAddressLogic.statusText(.mainAddress), tone: .warning)
        }
        let status = ReceiveAddressLogic.status(
            for: row,
            rotate: rotateReceiveAddress,
            isManualPick: walletManager.isManualReceiveSelection(index: row.index)
        )
        return StatusLine(text: ReceiveAddressLogic.statusText(status), tone: row.isUsed ? .used : .unused)
    }

    private func card(_ s: Snapshot, focus: QRFocus, onShowAddresses: (() -> Void)?, footer: AnyView? = nil) -> some View {
        let line = statusLine(s)
        let content = qrContent(for: s.shown)
        return ReceiveAddressCard(
            row: s.shown,
            qrContent: content,
            status: line.text,
            tone: line.tone,
            limitNote: ReceiveAddressLogic.limitText(s.limit),
            keysUnavailable: keysUnavailable,
            isCreating: isCreating,
            canCreate: canCreate(s),
            onRetry: loadTimedOut && s.shown == nil && !keysUnavailable ? retryOpen : nil,
            plateSide: plateSide,
            compact: isSquat,
            footer: footer,
            requestAmount: requestedXMR.flatMap { $0 > 0 ? $0 : nil },
            focus: focus,
            faceTransition: faceTransition,
            infoFocus: $cardInfoFocused,
            onNew: createAddress,
            onSaveToPhotos: { saveQRToPhotos(content: content) },
            onShowAddresses: onShowAddresses
        )
    }

    private func addressCards(_ s: Snapshot, layout: AddressCardsView.Layout) -> some View {
        AddressCardsView(
            layout: layout,
            mainRow: s.mainRow,
            rows: s.rows,
            selectedIndex: s.shown?.index ?? selectedAddressIndex,
            isCreating: isCreating,
            canCreate: canCreate(s),
            onUse: use,
            onCreate: createAddress,
            onSaveLabel: saveLabel,
            onClose: layout == .column ? nil : closeStack
        )
    }

    // MARK: Request amount

    @ViewBuilder
    private var requestSection: some View {
        if isSquat && !showsRequestField && requestAmount.isEmpty && requestFiatAmount.isEmpty {
            // Short screens: the field waits behind a pill (disclose).
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showsRequestField = true
                }
            } label: {
                Label(String(localized: "Request amount", comment: "Receive: shows the amount field on short screens"), systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            requestField
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var requestField: some View {
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
                        .onChange(of: requestFiatAmount) {
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
    }

    // MARK: Buttons

    private func actionButtons(_ s: Snapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                copyAddress(s.shown)
            } label: {
                Label(copied ? String(localized: "Copied!") : String(localized: "Copy"),
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(copied ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isSquat ? 10 : 14)
            }
            .glassButtonStyle()
            .accessibilityIdentifier("receive.copyButton")
            .accessibilityLabel(copied ? "Address copied" : "Copy address")
            .accessibilityHint("Copies the Monero address to clipboard")

            Button {
                showShareSheet = true
            } label: {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isSquat ? 10 : 14)
            }
            .glassButtonStyle()
            .accessibilityLabel("Share address")
            .accessibilityHint("Opens share sheet with QR code and address")
        }
        .disabled(s.shown == nil || keysUnavailable)
    }

    // MARK: Actions

    private func openStack() {
        HapticFeedback.shared.softTick()
        endEditing()
        showsStack = true
        // VoiceOver starts over on the cards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    private func closeStack() {
        endEditing()
        showsStack = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// The card follows the selection with the motion its cause calls for,
    /// always in place: New Address settles the new card in where the old
    /// one was, a pick and rotation cross-fade. Reduce Motion: a short fade.
    private func showSelection(from old: Int, to new: Int) {
        creationFailed = false
        let swap = nextSwap
        nextSwap = .rotation
        let animation: Animation
        if reduceMotion {
            faceTransition = .opacity
            animation = .easeInOut(duration: 0.2)
        } else {
            switch swap {
            case .newAddress:
                faceTransition = .asymmetric(
                    insertion: .scale(scale: 0.96).combined(with: .opacity),
                    removal: .opacity
                )
                animation = .spring(response: 0.5, dampingFraction: 0.86)
            case .pick:
                faceTransition = .opacity
                animation = .easeInOut(duration: 0.3)
            case .rotation:
                faceTransition = .opacity
                animation = .easeInOut(duration: 0.25)
            }
        }
        // One beat later, so the old card leaves with the transition set above.
        DispatchQueue.main.async {
            withAnimation(animation) {
                displayedIndex = new
            }
        }
    }

    /// A tap on an address card: it becomes the Receive card. On iPhone the
    /// cards close onto it.
    private func use(_ index: Int) {
        // Picking the address already shown changes nothing to animate.
        if index != (displayedIndex ?? selectedAddressIndex) {
            nextSwap = .pick
        }
        HapticFeedback.shared.softTick()
        walletManager.noteManualReceiveSelection(index: index)
        if showsStack {
            closeStack()
        }
    }

    private func createAddress() {
        // The buttons are off at the lookahead stop too; checked here as
        // well so no path can derive past it.
        guard !isCreating, canCreate(snapshot) else { return }
        HapticFeedback.shared.softTick()
        isCreating = true
        creationFailed = false
        Task {
            nextSwap = .newAddress
            let result = await walletManager.createAndSelectSubaddress { new in
                created = ReceiveAddressRow(index: new.index, address: new.address, label: new.label)
            }
            isCreating = false
            guard let result else {
                nextSwap = .rotation
                creationFailed = true
                HapticFeedback.shared.error()
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Couldn't create an address. Try again.", comment: "Receive card: New Address failed")
                )
                return
            }
            let row = ReceiveAddressRow(index: result.index, address: result.address, label: result.label)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Showing new address, \(row.name)", comment: "VoiceOver: announced after New Address")
            )
            try? await Task.sleep(for: .milliseconds(600))
            cardInfoFocused = true
        }
    }

    private func retryOpen() {
        loadTimedOut = false
        loadAttempt += 1
        Task { await walletManager.refresh() }
    }

    /// Saves a name typed on an address card; an empty one clears it.
    private func saveLabel(_ index: Int, _ label: String) {
        guard index > 0, walletManager.setSubaddressLabel(index: index, label: label) else { return }
        if let created, created.index == index {
            self.created = ReceiveAddressRow(index: index, address: created.address, label: label)
        }
        // A name reserves the address. Naming the one on screen keeps it
        // there until it gets paid, rather than rotation moving past the
        // name the user just gave it.
        if !label.isEmpty, index == selectedAddressIndex, !walletManager.isManualReceiveSelection(index: index) {
            walletManager.noteManualReceiveSelection(index: index)
        }
    }

    private func endEditing() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    /// Writes the QR to the photo library (add-only permission, prompted on
    /// first use). Success and failure are both announced for VoiceOver.
    private func saveQRToPhotos(content: String) {
        guard let image = QRCodeRenderer.renderToImage(content: content) else { return }
        UIImageWriteToSavedPhotosAlbum(
            image,
            PhotoSaveResponder.shared,
            #selector(PhotoSaveResponder.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private func shareItems(for row: ReceiveAddressRow?) -> [Any] {
        guard let row else { return [] }
        var items: [Any] = []

        // Generate QR code image
        if let qrImage = QRCodeRenderer.renderToImage(content: qrContent(for: row)) {
            items.append(qrImage)
        }

        // Create share message
        var message = String(localized: "Send me Monero (XMR) at this address:\n\n\(row.address)")
        if let amount = requestedXMR, amount > 0 {
            message = String(localized: "Send me \(requestAmount) XMR at this address:\n\n\(row.address)")
        }
        items.append(message)

        return items
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

    private func copyAddress(_ row: ReceiveAddressRow?) {
        guard let row, !keysUnavailable else { return }
        UIPasteboard.general.string = row.address
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

private extension View {
    /// iPad and the unfolded Duo: a page-sized sheet, wide enough for the
    /// card and the address list side by side. iPhone sheets ignore it.
    @ViewBuilder
    func receiveSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
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
