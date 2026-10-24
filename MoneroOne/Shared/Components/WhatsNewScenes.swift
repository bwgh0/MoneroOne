import SwiftUI

// What's New feature rows (spec: _scratch/2026-10-24-whats-new-r2): the
// picture above each row's text. Each scene is the app's own views with
// sample data, laid out at the default text size and scaled as one
// picture. No scene runs wallet logic or reads a store.

/// The part fills of the pictures, as on a wallet home: white in light,
/// #1C1C1E in dark. They resolve at the base level, so in dark they stay
/// darker than the card's #2C2C2E cell fill in the sheet. The hairline
/// keeps a white part's edge on the light card.
enum WhatsNewSceneColor {
    static let part = Color(uiColor: UIColor { traits in
        UIColor.secondarySystemGroupedBackground.resolvedColor(
            with: traits.modifyingTraits { $0.userInterfaceLevel = .base }
        )
    })
    static let hairline = Color(uiColor: .separator)
}

/// The picture of one highlight: the scene laid out at its native width,
/// then scaled as one picture to the width the row gives it (the envelope
/// takes 96% of it). It keeps that size at every text size.
struct WhatsNewScenePicture: View {
    let scene: WhatsNewScene

    var body: some View {
        let nativeWidth = nativeWidth
        ScaledPictureLayout(nativeWidth: nativeWidth, fill: fill) {
            content.frame(width: nativeWidth)
        }
        // The layout reports the scaled size; this draws the scene at it.
        .visualEffect { content, proxy in
            content.scaleEffect(proxy.size.width / nativeWidth)
        }
        // Each scene is laid out at the default size, then scaled.
        .dynamicTypeSize(.large)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch scene {
        case .transfer: TransferScene()
        case .link: LinkScene()
        case .contacts: ContactsScene()
        case .name: NameScene()
        case .seed: SeedScene()
        }
    }

    /// Each scene's native width. Transfer keeps "Everyday Spending" whole.
    private var nativeWidth: CGFloat {
        switch scene {
        case .transfer: 370
        case .link: LinkScene.width
        case .contacts: 320
        case .name, .seed: 300
        }
    }

    /// The share of the given width the picture takes. The envelope stays
    /// a little narrower than the scenes of parts, as in round 2 (178 of
    /// 186).
    private var fill: CGFloat {
        scene == .link ? 178.0 / 186.0 : 1
    }
}

/// Lays its one subview out at the native width and reports it scaled to
/// `fill` of the proposed width, so the row sees the picture at the size
/// it draws. The subview stays centered at its native size until the
/// picture's `visualEffect` scales it.
private struct ScaledPictureLayout: Layout {
    let nativeWidth: CGFloat
    let fill: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let native = CGSize(
            width: nativeWidth,
            height: subview.sizeThatFits(ProposedViewSize(width: nativeWidth, height: nil)).height
        )
        // Fits the proposed box: the card's inside, or only a width.
        let box = CGSize(width: proposal.width ?? nativeWidth, height: proposal.height ?? .infinity)
        let scale = WhatsNewFeatureLayout.pictureScale(native: native, fill: fill, in: box)
        return CGSize(width: native.width * scale, height: native.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: nativeWidth, height: nil)
        )
    }
}

// MARK: - Shared

/// The raised shadow of the parts, light mode only (`elevation.raised`).
private struct SceneShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 4, x: 0, y: 2)
    }
}

private extension View {
    func sceneShadow() -> some View { modifier(SceneShadow()) }

    /// A part of a picture: the part fill, the hairline and the raised
    /// shadow.
    func scenePart<S: InsettableShape>(_ shape: S) -> some View {
        background(WhatsNewSceneColor.part, in: shape)
            .overlay { shape.strokeBorder(WhatsNewSceneColor.hairline, lineWidth: 0.5) }
            .sceneShadow()
    }
}

/// Sample addresses: only their 8…8 short form shows.
private enum SceneSample {
    static func address(_ head: String, _ tail: String) -> String {
        head + String(repeating: "1", count: 79) + tail
    }
}

// MARK: - Transfer between your wallets

/// Two wallet switcher rows (the current one with its brand ring) and the
/// Transfer button, as in the wallet list.
private struct TransferScene: View {
    var body: some View {
        VStack(spacing: 12) {
            SceneWalletRow(
                name: String(localized: "Everyday Spending", comment: "What's New picture: a sample wallet name"),
                emoji: "\u{1F4B0}",
                balance: Decimal(string: "1284.503917") ?? 0,
                address: SceneSample.address("4AdUndXH", "5ZDxJ8Bq"),
                isActive: true
            )
            SceneWalletRow(
                name: String(localized: "Long-Term Savings Wallet", comment: "What's New picture: a sample wallet name"),
                emoji: "\u{1F3D4}\u{FE0F}",
                balance: Decimal(string: "0.25") ?? 0,
                address: SceneSample.address("86yLe8Lm", "QHv5ezC1"),
                isActive: false
            )
            // `WalletManagerRows.transferButton`, half the row's width.
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title3)
                Text("Transfer")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.brand)
            .padding(.vertical, 14)
            .frame(width: 179)
            .scenePart(Capsule())
        }
    }
}

/// A wallet switcher row's look: the handle, `WalletRowContent`, the pencil
/// and the check, on the row capsule.
private struct SceneWalletRow: View {
    let name: String
    let emoji: String
    let balance: Decimal
    let address: String
    let isActive: Bool
    @EnvironmentObject private var priceService: PriceService

    private var wallet: WalletInfo {
        WalletInfo(
            id: UUID(),
            name: name,
            emoji: emoji,
            source: .seed(.polyseed),
            createdAt: .distantPast,
            restoreHeight: 0,
            syncResetCount: 0,
            userCreatedSubaddressIndices: [],
            cachedPrimaryAddress: address,
            cachedBalance: balance
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            // Fiat Mode, as the switcher rows: the sample XMR at the live
            // price, XMR while there is no price.
            WalletRowContent(
                wallet: wallet,
                balance: balance,
                address: address,
                fiatBalance: priceService.showFiatFirst ? priceService.formatFiatValue(balance) : nil
            ) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(width: 24, height: 24)
                WalletRowCheck(isSelected: isActive)
            }
        }
        // The mockup's row: 16 on every side, without the glass button's
        // own side inset, so the first sample name shows whole.
        .padding(16)
        .background(WhatsNewSceneColor.part, in: Capsule())
        .overlay {
            // The current wallet's brand ring takes the hairline's place.
            Capsule().strokeBorder(
                isActive ? Color.brand.opacity(0.7) : WhatsNewSceneColor.hairline,
                lineWidth: isActive ? 1.5 : 0.5
            )
        }
        .sceneShadow()
    }
}

// MARK: - Send XMR as a link

/// The sealed envelope of the Link ready step with "0.5000 XMR" in foil,
/// 178 pt wide.
private struct LinkScene: View {
    static let width: CGFloat = 178
    private static let unit: CGFloat = width / Envelope.width

    var body: some View {
        ZStack(alignment: .topLeading) {
            EnvelopeBack()
            EnvelopeFront(sweep: Envelope.sweepEnd) {
                PaymentLinkCardFoil(amount: PaymentLinkCard.foil("0.5000", showsUnit: true), showsUnit: true)
                    .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
            }
        }
        .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
        .scaleEffect(Self.unit, anchor: .topLeading)
        .frame(width: Envelope.width * Self.unit, height: Envelope.height * Self.unit, alignment: .topLeading)
    }
}

// MARK: - Contacts

/// Three contact rows (`ContactRowContent`'s layout) with a person emoji in
/// each disc. Only this picture shows emoji; contacts in the app keep
/// their initials.
private struct ContactsScene: View {
    var body: some View {
        VStack(spacing: 12) {
            SceneContactRow(emoji: "\u{1F469}\u{1F3FD}", name: "Ana Souza", destination: .name("ana@example.com"))
            SceneContactRow(emoji: "\u{1F468}\u{1F3FB}", name: "Kenji Mori", destination: .address(SceneSample.address("88WNmfKy", "kJ7SPNG4")))
            SceneContactRow(emoji: "\u{1F469}\u{1F3FC}\u{200D}\u{1F9B0}", name: "Lena Fischer", destination: .name("lena@example.org"))
        }
    }
}

private struct SceneContactRow: View {
    enum Destination {
        case name(String)
        case address(String)
    }

    let emoji: String
    let name: String
    let destination: Destination

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: emoji)
                .font(.system(size: 32))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                switch destination {
                case .name(let text):
                    Text(verbatim: text)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                case .address(let address):
                    Text(verbatim: ReceiveAddressLogic.shortAddress(address))
                        .font(.caption)
                        .monospaced()
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .scenePart(Capsule())
    }
}

// MARK: - Send to a name

/// The Send step with a resolved name: "Recipient", the field as
/// `OpenAliasRecipientCard` and the DNSSEC line with the 8…8 address.
/// No Continue capsule: it sat above the sheet's real Continue and read
/// as a button.
private struct NameScene: View {
    private let summary = OpenAliasSummary(
        name: OpenAliasName(display: "ana@example.com", query: "ana.example.com"),
        address: SceneSample.address("4AdUndXH", "5ZDxJ8Bq"),
        dnssec: .valid,
        pin: .none,
        recipientName: "Ana Souza"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipient")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // `OpenAliasRecipientCard`'s look with the names in `Text`: the
            // card's name is a UITextView, which grows with the system text
            // size, and the picture stays at the default size.
            HStack(spacing: 12) {
                RecipientAvatar(summary: summary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: summary.recipientName ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: summary.name.display)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .scenePart(RoundedRectangle(cornerRadius: 12))

            OpenAliasResolvedLines(summary: summary)
        }
    }
}

// MARK: - New seed phrase entry

/// Words 21 to 25 in the seed grid's two columns, then "Valid seed
/// phrase" with its green check, as on the restore screen.
private struct SeedScene: View {
    private let words = SeedSceneWords.words(for: AppLanguageSetting.current.code)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    SceneSeedCell(number: 21, word: words[0])
                    SceneSeedCell(number: 22, word: words[1])
                }
                GridRow {
                    SceneSeedCell(number: 23, word: words[2])
                    SceneSeedCell(number: 24, word: words[3])
                }
                GridRow {
                    SceneSeedCell(number: 25, word: words[4])
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Valid seed phrase")
            }
            .font(.subheadline)
            .foregroundStyle(.green)
        }
    }
}

/// `SeedWordCell`'s look: "N." in secondary, the word in monospaced text.
private struct SceneSeedCell: View {
    let number: Int
    let word: String

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "25.")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: "\(number).")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.monospacedDigit())

            Text(verbatim: word)
                .font(.body.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .scenePart(RoundedRectangle(cornerRadius: 12))
    }
}

/// Sample words 21 to 25 from the Monero (legacy) word list of the app
/// language, else English. The same list positions in each language
/// (English: tuesday, gnome, vexed, sapling, jaded).
enum SeedSceneWords {
    static func words(for languageCode: String) -> [String] {
        switch languageCode {
        case "de": ["Skizze", "Exodus", "Umgang", "Ölberg", "Garten"]
        case "es": ["pétalo", "doble", "pulmón", "natal", "fiable"]
        case "fr": ["stock", "foin", "trier", "rasoir", "infime"]
        case "it": ["sudare", "esame", "uffa", "riflesso", "geologia"]
        case "ja": ["にっすう", "けとる", "のはら", "ついか", "こんれい"]
        case "nl": ["varaan", "gogme", "weert", "secessie", "kipschnitzel"]
        case "pt-BR": ["tchecoslovaco", "fiquei", "ursulina", "ptialina", "honroso"]
        case "ru": ["флейта", "картина", "шампунь", "социолог", "льгота"]
        case "zh-Hans": ["幕", "树", "抬", "嘴", "胜"]
        default: ["tuesday", "gnome", "vexed", "sapling", "jaded"]
        }
    }
}
