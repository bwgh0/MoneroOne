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
/// version, three highlight rows, Other Improvements, one Continue button.
struct WhatsNewSheet: View {
    let entry: WhatsNewEntry
    @Environment(\.dismiss) private var dismiss

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

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(entry.highlights, id: \.systemImage) { highlight in
                        WhatsNewHighlightRow(highlight: highlight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)

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
                                        .frame(width: 8)
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

/// An icon disc (the Activity rows' 40 pt tinted disc), a title and two
/// lines. One VoiceOver element: the title, then the text.
private struct WhatsNewHighlightRow: View {
    let highlight: WhatsNewEntry.Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: highlight.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.brand)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .font(.headline)
                Text(highlight.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
