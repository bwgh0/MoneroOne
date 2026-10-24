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

/// Apple's "What's New in Pages" pattern: a large centered title, the
/// version, the highlight rows, Other Improvements, one Continue button.
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
            VStack(spacing: 0) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("Version \(entry.version.description)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 24 : WhatsNewFeatureLayout.rowSpacing) {
                    ForEach(Array(entry.highlights.enumerated()), id: \.element.systemImage) { index, highlight in
                        WhatsNewFeatureRow(highlight: highlight, row: index)
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .readableColumn()
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .glassButtonStyle()
            .padding(.horizontal)
            .padding(.bottom, 8)
            .readableColumn()
            .accessibilityIdentifier("whatsNew.continue")
        }
        .closesForPaymentLink()
    }
}

/// The layout of the feature rows: each picture on its own line, 70% of
/// the content width, at the trailing edge for row 1, the leading edge for
/// row 2, and so on. Each tilts a little, by a different angle on each
/// row, and slopes down toward the next picture. The title and the line
/// sit under the picture at the full content width.
enum WhatsNewFeatureLayout {
    /// The picture's share of the content width.
    static let pictureShare: CGFloat = 0.7
    /// The space between a picture and its title.
    static let pictureToText: CGFloat = 20
    /// The space between two rows (24 at the accessibility text sizes,
    /// where the pictures hide).
    static let rowSpacing: CGFloat = 40
    /// The tilt of each row's picture in degrees, row 1 first. A trailing
    /// picture turns counterclockwise (negative) and a leading one
    /// clockwise, so each slopes down toward the next one.
    static let tilts: [Double] = [-4, 3, -2, 4, -3]

    /// Row 1 (index 0) puts its picture at the trailing edge.
    static func pictureTrailing(row: Int) -> Bool {
        row.isMultiple(of: 2)
    }

    static func tilt(row: Int) -> Double {
        tilts[row % tilts.count]
    }

    static func pictureWidth(contentWidth: CGFloat) -> CGFloat {
        contentWidth * pictureShare
    }
}

/// One feature row, nothing behind it (the rows of Apple's What's New in
/// Pages): the picture on its own line on one soft brand glow, then the
/// title and the line. `WhatsNewFeatureLayout` sets the picture's width,
/// edge and tilt. Everything is in place when the sheet opens, with no
/// entrance motion. At the accessibility text sizes the picture hides.
/// One VoiceOver element: the title, then the line; the picture is hidden
/// from VoiceOver.
private struct WhatsNewFeatureRow: View {
    let highlight: WhatsNewEntry.Highlight
    /// The row's place in the list, from 0.
    let row: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            text
        } else {
            VStack(alignment: .leading, spacing: WhatsNewFeatureLayout.pictureToText) {
                picture
                text
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlight.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(highlight.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var picture: some View {
        WhatsNewPictureSlot(trailing: WhatsNewFeatureLayout.pictureTrailing(row: row)) {
            WhatsNewScenePicture(scene: highlight.scene)
                .rotationEffect(.degrees(WhatsNewFeatureLayout.tilt(row: row)))
                .background { WhatsNewGlow().padding(-50) }
        }
    }
}

/// Takes the full content width, offers the picture its share of it and
/// puts it at the leading or the trailing edge.
private struct WhatsNewPictureSlot: Layout {
    let trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let picture = subviews.first else { return .zero }
        let size = picture.sizeThatFits(pictureProposal(proposal.width))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let picture = subviews.first else { return }
        let pictureProposal = pictureProposal(bounds.width)
        let width = picture.sizeThatFits(pictureProposal).width
        picture.place(
            at: CGPoint(x: trailing ? bounds.maxX - width : bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: pictureProposal
        )
    }

    private func pictureProposal(_ width: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: width.map(WhatsNewFeatureLayout.pictureWidth(contentWidth:)), height: nil)
    }
}

/// The brand glow behind a picture: full strength under it, then a soft
/// fall-off to clear 50 pt past its edge. 0.08 in light (a section glow),
/// 0.12 in dark (token `glow`).
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
