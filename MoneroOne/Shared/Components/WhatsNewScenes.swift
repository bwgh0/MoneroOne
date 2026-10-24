import SwiftUI

// What's New feature cards (spec: _scratch/2026-10-23-whats-new-cards): the
// picture at the top of each card. Each scene is the app's own views with
// sample data, laid out at the default text size and scaled as one
// picture. No scene runs wallet logic or reads a store.

/// The card and part fills of the pictures. A sheet raises the system
/// colors one level in dark mode (the grouped page becomes #1C1C1E, like
/// the sheet), so these resolve at the base level: the card is the grouped
/// page (#F2F2F7 / #000000) and the parts are cards on it (#FFFFFF /
/// #1C1C1E), as they sit in the app.
enum WhatsNewSceneColor {
    static let card = Color(uiColor: UIColor { traits in
        UIColor.systemGroupedBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .base })
    })
    static let part = Color(uiColor: UIColor { traits in
        UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .base })
    })
}

/// The picture of one highlight: the top 208 pt of a 354 pt card, the same
/// ratio on a wider card.
struct WhatsNewScenePicture: View {
    let scene: WhatsNewScene

    /// The card's width and picture height in the mockup (a 402 pt phone).
    static let baseWidth: CGFloat = 354
    static let baseHeight: CGFloat = 208

    var body: some View {
        Color.clear
            .aspectRatio(Self.baseWidth / Self.baseHeight, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let fit = proxy.size.width / Self.baseWidth
                    content
                        .scaleEffect(scale * fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
            // Each scene is laid out at the default size, then scaled.
            .dynamicTypeSize(.large)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Each scene at its native width.
    @ViewBuilder
    private var content: some View {
        switch scene {
        case .transfer: TransferScene().frame(width: 370).fixedSize(horizontal: false, vertical: true)
        case .link: LinkScene()
        case .contacts: ContactsScene().frame(width: 370).fixedSize(horizontal: false, vertical: true)
        case .name: NameScene().frame(width: 360).fixedSize(horizontal: false, vertical: true)
        case .seed: SeedScene().frame(width: 360).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scale: CGFloat {
        switch scene {
        case .transfer: 0.66
        case .link: 1
        case .contacts: 0.68
        case .name: 0.85
        case .seed: 0.87
        }
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
            .background(WhatsNewSceneColor.part, in: Capsule())
            .sceneShadow()
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
            Capsule().strokeBorder(Color.brand.opacity(isActive ? 0.7 : 0), lineWidth: 1.5)
        }
        .sceneShadow()
    }
}

// MARK: - Send XMR as a link

/// The sealed envelope of the Link ready step with "0.5000 XMR" in foil,
/// 236 pt wide.
private struct LinkScene: View {
    private static let unit: CGFloat = 236 / Envelope.width

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
        .background(WhatsNewSceneColor.part, in: Capsule())
        .sceneShadow()
    }
}

// MARK: - Send to a name

/// The Send step with a resolved name: "Recipient", the field as
/// `OpenAliasRecipientCard`, the DNSSEC line with the 8…8 address, and
/// Continue. Change 2 of the spec: it fills the picture like the others.
private struct NameScene: View {
    private let summary = OpenAliasSummary(
        name: OpenAliasName(display: "ana@example.com", query: "ana.example.com"),
        address: SceneSample.address("4AdUndXH", "5ZDxJ8Bq"),
        dnssec: .valid,
        pin: .none,
        recipientName: "Ana Souza"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipient")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                OpenAliasRecipientCard(summary: summary, onClear: {})
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                    .background(WhatsNewSceneColor.part, in: RoundedRectangle(cornerRadius: 12))
                    .sceneShadow()

                OpenAliasResolvedLines(summary: summary)
            }

            // The step's Continue, enabled.
            HStack(spacing: 8) {
                Text("Continue")
                    .font(.callout.weight(.semibold))
                Image(systemName: "arrow.right")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(WhatsNewSceneColor.part, in: Capsule())
            .sceneShadow()
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
        .background(WhatsNewSceneColor.part, in: RoundedRectangle(cornerRadius: 12))
        .sceneShadow()
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
