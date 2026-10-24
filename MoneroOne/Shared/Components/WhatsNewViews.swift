import SwiftUI

// MARK: - Banner

/// One line under the greeting after a big update: sparkles, "What's New
/// in Monero One 1.1", X. A tap opens the sheet; the X hides it for good.
/// Banner grammar like `ErrorBanner`, with a green tint (green is not a
/// fault color, and orange read as the red error banners).
struct WhatsNewBanner: View {
    let entry: WhatsNewEntry
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.body)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    // No line limit: at large text sizes it wraps and the
                    // banner grows taller, never wider.
                    Text("What's New in Monero One \(entry.version.description)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("whatsNew.banner")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("whatsNew.close")
        }
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The What's New banner in a home header, after the Testnet, Offline and
/// sync-error banners. One banner at a time: while one of those shows,
/// this one waits, and its 30-day clock does not start.
struct WhatsNewBannerSlot: View {
    @Binding var presented: WhatsNewEntry?
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var model = WhatsNewModel.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    private var otherBannerShows: Bool {
        if walletManager.isTestnet || !networkMonitor.isConnected { return true }
        if case .error = walletManager.syncState { return true }
        return false
    }

    var body: some View {
        if let entry = model.bannerEntry, !otherBannerShows {
            WhatsNewBanner(
                entry: entry,
                onOpen: {
                    model.openFromBanner(entry)
                    presented = entry
                },
                onClose: { model.close(entry) }
            )
            .onAppear { model.bannerShown(entry) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// For a wallet home: the What's New sheet that its banner opens, and
    /// the 30-day check each time the home appears. Put it on a view that
    /// stays on screen, so an Offline banner taking the slot does not close
    /// an open sheet.
    func whatsNewHome(presented: Binding<WhatsNewEntry?>) -> some View {
        self
            .sheet(item: presented, onDismiss: { WhatsNewModel.shared.sheetClosed() }) { entry in
                WhatsNewSheet(entry: entry)
            }
            .onAppear { WhatsNewModel.shared.homeAppeared() }
    }
}

// MARK: - Sheet

/// The links at the end of the sheet.
enum WhatsNewLinks {
    /// Share with Friends: the download page, which sends each device to
    /// its store (friends may use Android).
    static let share = URL(string: "https://monero.one/download")!
    /// Rate on the App Store: the write-review page, as Settings > Rate
    /// Monero One. Apple's review prompt may show nothing, so it is not used.
    static let rate = URL(string: "https://apps.apple.com/app/id6757898541?action=write-review")!
}

/// Flighty's What's New layout: the app icon and the version in a small
/// row, a large leading title, one full-width card per feature with its
/// title and line under it, Other Improvements, then Share with Friends
/// and Rate on the App Store. The X at the top right stays in place while
/// the sheet scrolls and closes it, as Continue did (the sheet's
/// `onDismiss` keeps the "seen" bookkeeping).
struct WhatsNewSheet: View {
    let entry: WhatsNewEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The bullet's column grows with the text, so the dot is never cut.
    @ScaledMetric(relativeTo: .subheadline) private var bulletWidth: CGFloat = 8

    /// Keeps "Monero One" on one line when the title wraps. The name stays
    /// in Latin letters in every language.
    private var title: String {
        String(localized: "What's New in Monero One")
            .replacingOccurrences(of: "Monero One", with: "Monero\u{00A0}One")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Text(title)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 24)

                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 24 : WhatsNewFeatureLayout.rowSpacing) {
                    ForEach(entry.highlights, id: \.systemImage) { highlight in
                        WhatsNewFeatureRow(highlight: highlight)
                    }
                }
                .padding(.top, 32)

                if !entry.improvements.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Other Improvements")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entry.improvements.indices, id: \.self) { index in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: "•")
                                        .foregroundStyle(.tertiary)
                                        .frame(width: bulletWidth)
                                        .accessibilityHidden(true)
                                    Text(entry.improvements[index])
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 40)
                }

                links
                    .padding(.top, 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, WhatsNewFeatureLayout.closeInset)
            .padding(.bottom, 24)
            .readableColumn()
        }
        .overlay(alignment: .topTrailing) {
            WhatsNewCloseButton { dismiss() }
                .padding(.top, WhatsNewFeatureLayout.closeInset)
                .padding(.trailing, WhatsNewFeatureLayout.closeInset)
        }
        .closesForPaymentLink()
    }

    /// The app icon and "Version 1.1", lined up with the X while the sheet
    /// is at its top. The trailing room keeps a wrapped version clear of it.
    private var header: some View {
        HStack(spacing: 12) {
            Image("MoneroSymbol")
                .resizable()
                .scaledToFit()
                .frame(width: WhatsNewFeatureLayout.iconSize, height: WhatsNewFeatureLayout.iconSize)
                // A hairline keeps the white tile visible on the white sheet.
                .overlay {
                    RoundedRectangle(cornerRadius: WhatsNewFeatureLayout.iconCornerRadius, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
            Text("Version \(entry.version.description)")
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: WhatsNewFeatureLayout.closeSize)
        .padding(.trailing, WhatsNewFeatureLayout.closeSize)
    }

    /// Two centered text buttons, no background, as at the end of Flighty's
    /// What's New.
    private var links: some View {
        VStack(spacing: 4) {
            ShareLink(item: WhatsNewLinks.share) {
                linkLabel("Share with Friends", systemImage: "paperplane.fill")
            }
            .accessibilityIdentifier("whatsNew.share")

            Link(destination: WhatsNewLinks.rate) {
                linkLabel("Rate on the App Store", systemImage: "star.fill")
            }
            .accessibilityIdentifier("whatsNew.rate")
            // The person rated here: the app never asks for Apple's review
            // prompt after a send (as Settings > Rate Monero One).
            .environment(\.openURL, OpenURLAction { _ in
                ReviewPromptGate().ratedFromSettings()
                return .systemAction
            })
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func linkLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.brand)
            .multilineTextAlignment(.center)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The sheet's X: a 44 pt glass circle (a material circle before iOS 26).
private struct WhatsNewCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: WhatsNewFeatureLayout.closeSize, height: WhatsNewFeatureLayout.closeSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(WhatsNewCloseSurface())
        .accessibilityLabel("Close")
        .accessibilityIdentifier("whatsNew.sheetClose")
    }
}

private struct WhatsNewCloseSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

/// The layout of the sheet and its feature cards (Flighty's What's New):
/// each feature is a full-width card with its picture centered and
/// straight, then the title and the line, inset to line up with the
/// card's inner edge.
enum WhatsNewFeatureLayout {
    /// The card's width to its height. 16:10, a little taller than 16:9,
    /// so the taller pictures (Transfer, Contacts) stay readable.
    static let cardAspectRatio: CGFloat = 16.0 / 10.0
    static let cardCornerRadius: CGFloat = 20
    /// The room around the picture inside the card.
    static let cardPadding: CGFloat = 16
    /// The space between a card and its title.
    static let cardToText: CGFloat = 16
    /// The title and the line start this far in, at the card's inner edge.
    static let textInset: CGFloat = 12
    /// The space between two features (24 at the accessibility text sizes,
    /// where the cards hide).
    static let rowSpacing: CGFloat = 40
    /// The X: its size, and its distance from the top and the trailing edge.
    static let closeSize: CGFloat = 44
    static let closeInset: CGFloat = 16
    /// The blurred copy of the picture behind it: how much larger, how
    /// soft and how faint. Dark mode only: in light, a dark picture (the
    /// envelope) turns the card into a gray box, so light cards show only
    /// the fill and the glow.
    static let blurScale: CGFloat = 1.6
    static let blurRadius: CGFloat = 28
    static let blurOpacity: Double = 0.6
    /// The app icon in the header, and the radius of its tile.
    static let iconSize: CGFloat = 40
    static let iconCornerRadius: CGFloat = 9

    static func cardHeight(width: CGFloat) -> CGFloat {
        width / cardAspectRatio
    }

    /// The scale that fits a picture of `native` size into `box`, with
    /// `fill` of the box's width at most.
    static func pictureScale(native: CGSize, fill: CGFloat, in box: CGSize) -> CGFloat {
        guard native.width > 0, native.height > 0 else { return 1 }
        return min(box.width * fill / native.width, box.height / native.height)
    }
}

/// One feature: the card, then the title and the line. At the
/// accessibility text sizes the card hides. One VoiceOver element: the
/// title, then the line; the card is hidden from VoiceOver.
private struct WhatsNewFeatureRow: View {
    let highlight: WhatsNewEntry.Highlight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            text
        } else {
            VStack(alignment: .leading, spacing: WhatsNewFeatureLayout.cardToText) {
                WhatsNewFeatureCard(scene: highlight.scene)
                text
                    .padding(.horizontal, WhatsNewFeatureLayout.textInset)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlight.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(highlight.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A feature's card: the cell fill, the one brand glow, the picture blurred
/// large and faint (dark mode only), and the sharp picture centered on top,
/// straight.
private struct WhatsNewFeatureCard: View {
    let scene: WhatsNewScene
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(WhatsNewFeatureLayout.cardAspectRatio, contentMode: .fit)
            .overlay { WhatsNewGlow() }
            .overlay {
                WhatsNewScenePicture(scene: scene)
                    .scaleEffect(WhatsNewFeatureLayout.blurScale)
                    .blur(radius: WhatsNewFeatureLayout.blurRadius)
                    .opacity(colorScheme == .dark ? WhatsNewFeatureLayout.blurOpacity : 0)
            }
            .overlay {
                // The sharp picture plays its loop (only Transfer has one).
                WhatsNewScenePicture(scene: scene, isAnimated: true)
                    .padding(WhatsNewFeatureLayout.cardPadding)
            }
            .clipShape(RoundedRectangle(cornerRadius: WhatsNewFeatureLayout.cardCornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The brand glow in a card: full strength in the middle, then a soft
/// fall-off to clear at the edge. 0.08 in light (a section glow), 0.12 in
/// dark (token `glow`).
private struct WhatsNewGlow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let alpha = colorScheme == .dark ? 0.12 : 0.08
        EllipticalGradient(stops: [
            .init(color: .brand.opacity(alpha), location: 0.4),
            .init(color: .brand.opacity(alpha * 0.75), location: 0.58),
            .init(color: .brand.opacity(alpha * 0.42), location: 0.74),
            .init(color: .brand.opacity(alpha * 0.15), location: 0.88),
            .init(color: .brand.opacity(0), location: 1),
        ])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Banner") {
    VStack(spacing: 8) {
        WhatsNewBanner(entry: WhatsNewNotes.entries[0], onOpen: {}, onClose: {})
    }
    .padding()
}

#Preview("Sheet") {
    Text(verbatim: "Home")
        .sheet(isPresented: .constant(true)) {
            WhatsNewSheet(entry: WhatsNewNotes.entries[0])
        }
}
