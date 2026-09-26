import SwiftUI

/// How the card's status line reads.
enum ReceiveStatusTone {
    case unused, used, warning, error

    var color: Color {
        switch self {
        case .unused, .used: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// The Receive screen's address card: name, QR, full address and a status
/// line that says what happens after the next payment. Older addresses show
/// as thin edges behind it, like a deck. Every slot keeps its size while
/// the address changes or loads, so nothing below the card moves.
struct ReceiveAddressCard: View {
    /// The shown address; nil while the wallet has none yet.
    let row: ReceiveAddressRow?
    let qrContent: String
    let status: String
    var tone: ReceiveStatusTone = .unused
    /// The seed-restore lookahead warning under the status, if any.
    var limitNote: String?
    let keysUnavailable: Bool
    let isCreating: Bool
    let canCreate: Bool
    /// Shown in the QR slot while the card waits, once waiting has gone on
    /// too long. Inside the slot, so the card keeps its height.
    var onRetry: (() -> Void)?
    /// How many other addresses the wallet has: the deck edges stand for them.
    let otherCount: Int
    /// One edge on squat screens, two elsewhere.
    var maxEdges = 2
    /// Side of the white plate the QR sits on, quiet zone included.
    let plateSide: CGFloat
    /// Short screens: 16pt padding and 12pt gaps instead of 24 and 16.
    var compact = false
    /// Content at the bottom of the card; short screens put Copy and Share
    /// here so they stay on screen.
    var footer: AnyView?
    /// The amount the code requests, for focus mode.
    let requestAmount: Decimal?
    /// The screen's QR focus mode: the plate opens it, and the rest of the
    /// card steps back while it is open.
    let focus: QRFocus
    /// Inserted and removed with this when the shown address changes.
    var faceTransition: AnyTransition = .opacity
    var infoFocus: AccessibilityFocusState<Bool>.Binding
    let onNew: () -> Void
    let onRename: () -> Void
    let onSaveToPhotos: () -> Void
    /// A tap on the deck edges; nil where the list is already on screen.
    var onOpenList: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    /// Three lines of the address at the current text size.
    @ScaledMetric(relativeTo: .footnote) private var addressSlotHeight: CGFloat = 54

    private static let cornerRadius: CGFloat = 20
    private static let edgeStep: CGFloat = 8

    private var edges: Int { min(maxEdges, otherCount) }

    var body: some View {
        ZStack(alignment: .bottom) {
            deckEdges
                .opacity(focus.isFocused ? 0 : 1)
            face
                .id(row?.index ?? -1)
                .transition(faceTransition)
        }
        .padding(.bottom, CGFloat(edges) * Self.edgeStep)
    }

    // MARK: Deck

    /// Older addresses as the edges of cards behind this one. Decorative:
    /// VoiceOver reaches the list through the Addresses button.
    private var deckEdges: some View {
        ZStack(alignment: .bottom) {
            ForEach((1...max(edges, 1)).reversed(), id: \.self) { layer in
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(edgeFill(layer))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    }
                    .shadow(color: .black.opacity(colorScheme == .light ? 0.06 : 0), radius: 8, y: 2)
                    .padding(.horizontal, CGFloat(layer) * 12)
                    .offset(y: CGFloat(layer) * Self.edgeStep)
                    .opacity(edges == 0 ? 0 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenList?() }
        .accessibilityHidden(true)
    }

    // MARK: Face

    /// A step darker per layer, so the cards behind read as a stack on a
    /// white page too.
    private func edgeFill(_ layer: Int) -> Color {
        if colorScheme == .dark {
            return Color(.secondarySystemGroupedBackground).opacity(layer == 1 ? 0.75 : 0.5)
        }
        return layer == 1 ? Color(.systemGray6) : Color(.systemGray5)
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
                .qrFocusRecede(focus, toward: .top)
            qrSlot
                .frame(maxWidth: .infinity)
            Group {
                addressSlot
                statusSlot
                if let footer {
                    footer
                }
            }
            .qrFocusRecede(focus, toward: .bottom)
        }
        .padding(compact ? 16 : 24)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(cardFill)
                .shadow(color: .black.opacity(colorScheme == .light ? 0.08 : 0), radius: 12, y: 4)
                .opacity(focus.isFocused ? 0 : 1)
        }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(.secondarySystemGroupedBackground) : Color(.systemBackground)
    }

    // MARK: Header

    /// Name, the Name pill for an unnamed subaddress, and New. A narrow card
    /// (a column on the unfolded Duo) drops the Name pill before it cuts the
    /// name: the name itself opens Rename too.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nameView
                    if let row, !row.isMain, !row.isLabeled {
                        Button(action: onRename) {
                            pill(String(localized: "Name", comment: "Receive card: pill that opens Rename for an unnamed subaddress"), systemImage: nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
                nameView
            }

            Spacer(minLength: 8)

            newButton
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var nameView: some View {
        if let row, !row.isMain {
            Button(action: onRename) {
                Text(row.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Rename, \(row.name)", comment: "VoiceOver: the Receive card's name button"))
            .accessibilityIdentifier("receive.card.name")
        } else {
            Text(row?.name ?? String(localized: "Main Address"))
                .font(.headline)
                .lineLimit(1)
                .accessibilityHidden(true)
                .redacted(reason: row == nil ? .placeholder : [])
        }
    }

    private var newButton: some View {
        Button(action: onNew) {
            ZStack {
                // Holds the pill's width while the spinner shows.
                pill(String(localized: "New", comment: "Receive card: creates a new subaddress"), systemImage: "plus")
                    .opacity(isCreating ? 0 : 1)
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.orange)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCreate || isCreating)
        .opacity(canCreate || isCreating ? 1 : 0.4)
        .padding(.vertical, -8)
        .fixedSize()
        .accessibilityLabel(isCreating
            ? String(localized: "Creating address", comment: "VoiceOver: New Address while it works")
            : String(localized: "New address", comment: "VoiceOver: the Receive card's New button"))
        .accessibilityHint(String(localized: "Creates a new subaddress and shows it here.", comment: "VoiceOver hint: New Address"))
        .accessibilityIdentifier("receive.newAddressButton")
    }

    private func pill(_ title: String, systemImage: String?) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15), in: Capsule())
    }

    // MARK: QR

    @ViewBuilder
    private var qrSlot: some View {
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
            .frame(width: plateSide, height: plateSide)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Wallet keys unavailable. No receive address can be shown.")
        } else if let row, !qrContent.isEmpty {
            FocusableQRPlate(
                item: QRFocusItem(content: qrContent, title: row.name, amount: requestAmount),
                side: plateSide,
                focus: focus,
                label: String(localized: "QR code for receiving Monero")
            )
            .contextMenu {
                Button(action: onSaveToPhotos) {
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
            // After the plate's own accessibility element: set before it,
            // the id sat on an ignored child and UI tests could not find
            // the code.
            .accessibilityIdentifier("receive.qrCode")
            .accessibilityHint("Shows the code full screen. Actions available: save to Photos, or share")
            .accessibilityAction(named: "Save to Photos", onSaveToPhotos)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .frame(width: plateSide, height: plateSide)
                .overlay {
                    if let onRetry {
                        VStack(spacing: 16) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Button(action: onRetry) {
                                Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                            }
                            .glassButtonStyle()
                            .accessibilityIdentifier("receive.retryButton")
                        }
                        .transition(.opacity)
                    } else {
                        GradientSpinner(iconName: "qrcode")
                            .scaleEffect(min(1, plateSide / 200))
                            .accessibilityElement()
                            .accessibilityLabel(String(localized: "Waiting for the address", comment: "VoiceOver: the Receive card's QR slot while the wallet opens"))
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: onRetry == nil)
        }
    }

    // MARK: Address and status

    /// The whole address, groups of four in two tints, so it can be checked
    /// by eye; a long press selects it. Placeholder lines while loading.
    @ViewBuilder
    private var addressSlot: some View {
        Group {
            if let row, !keysUnavailable {
                CodeText(row.address, style: .footnote, color: .label, selectable: true, groupTint: .secondaryLabel)
            } else {
                Text(String(repeating: "0000", count: 23))
                    .font(.footnote.monospaced())
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: addressSlotHeight, alignment: .topLeading)
    }

    private var statusSlot: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusIcon
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(tone.color)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limitNote {
                Text(limitNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One VoiceOver stop for the card's information: name, status and
        // how the address starts and ends; the whole address waits on the
        // More Content rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.map { ReceiveAddressLogic.spokenSummary(for: $0, status: status) } ?? status)
        .accessibilityCustomContent(AccessibilityCustomContentKey("Address"), row.map { Text(verbatim: $0.address) })
        .accessibilityFocused(infoFocus)
        .accessibilityIdentifier("receive.card.info")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tone {
        case .unused:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        case .used:
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
