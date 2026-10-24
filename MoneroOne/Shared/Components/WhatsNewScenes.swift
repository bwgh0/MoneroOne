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
    /// Plays the scene's loop. Only the envelope and Transfer have one; the
    /// blurred copy behind a card stays still.
    var isAnimated = false

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
        case .transfer: TransferScene(isAnimated: isAnimated)
        case .link: LinkScene(isAnimated: isAnimated)
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

/// The Transfer picture's loop (round 4, rule 5): Transfer is pressed, the
/// amount shows between the two wallets, the From balance rolls down, then
/// the To balance rolls up. A rest on the result, then the picture fades
/// out and comes back at the start.
enum WhatsNewTransferLoop {
    enum Step: CaseIterable {
        /// The picture as it stands: nothing has moved. It fades back in.
        case start
        /// Transfer is pressed.
        case press
        /// Transfer is let go and the amount shows between the wallets.
        case amount
        /// The amount leaves the From wallet: its balance rolls down.
        case sent
        /// The amount reaches the To wallet: its balance rolls up.
        case received
        /// The picture fades out, so the balances go back unseen.
        case fade
    }

    static let fromBalance = Decimal(string: "1284.503917") ?? 0
    static let toBalance = Decimal(string: "0.25") ?? 0
    static let amount: Decimal = 250

    /// The frame that stands still with Reduce Motion: the result, the last
    /// frame before the fade.
    static let stillStep: Step = .received

    /// The Transfer button's press (`motion.press`, larger than 0.98 so it
    /// reads at the picture's scale).
    static let pressScale: CGFloat = 0.96

    static func fromBalance(at step: Step) -> Decimal {
        switch step {
        case .start, .press, .amount: fromBalance
        case .sent, .received, .fade: fromBalance - amount
        }
    }

    static func toBalance(at step: Step) -> Decimal {
        switch step {
        case .start, .press, .amount, .sent: toBalance
        case .received, .fade: toBalance + amount
        }
    }

    static func showsAmount(at step: Step) -> Bool {
        switch step {
        case .start, .press, .fade: false
        case .amount, .sent, .received: true
        }
    }

    static func buttonScale(at step: Step) -> CGFloat {
        step == .press ? pressScale : 1
    }

    static func pictureOpacity(at step: Step) -> Double {
        step == .fade ? 0 : 1
    }

    /// The wait before the move to `step`: the rest on the start frame
    /// before the press, the time to read the amount, the gap between the
    /// two rolls, and the rest on the result before the fade.
    static func delay(before step: Step) -> Double {
        switch step {
        case .start, .amount: 0
        case .press: 1.4
        case .sent: 0.6
        case .received: 0.3
        case .fade: 2.0
        }
    }

    /// The length of the move to `step`: the fades (crossFade), the press,
    /// the settle spring's response, and the digit roll (rollDigits).
    static func duration(of step: Step) -> Double {
        switch step {
        case .start, .fade: 0.35
        case .press: 0.1
        case .amount: 0.4
        case .sent, .received: 0.2
        }
    }

    /// When the move to `step` begins, from the start of a cycle.
    static func begin(of step: Step) -> Double {
        var time = 0.0
        for earlier in Step.allCases {
            time += delay(before: earlier)
            if earlier == step { break }
            time += duration(of: earlier)
        }
        return time
    }

    /// One cycle, rests included.
    static var cycleDuration: Double {
        Step.allCases.reduce(0) { $0 + delay(before: $1) + duration(of: $1) }
    }

    /// The step shown `elapsed` seconds after the loop began. A time on a
    /// step's begin shows that step.
    static func step(at elapsed: Double) -> Step {
        let time = (max(0, elapsed) + 1e-6).truncatingRemainder(dividingBy: cycleDuration)
        return Step.allCases.last { begin(of: $0) <= time } ?? .start
    }

    /// The motion tokens: crossFade, press, settle, rollDigits.
    static func animation(to step: Step) -> Animation {
        let duration = duration(of: step)
        return switch step {
        case .amount: .spring(response: duration, dampingFraction: 0.8)
        case .start, .press, .sent, .received, .fade: .easeInOut(duration: duration)
        }
    }
}

/// Two wallet switcher rows (the current one with its brand ring) and the
/// Transfer button, as in the wallet list. On the top card it plays the
/// Transfer loop; with Reduce Motion it shows the loop's result, still.
private struct TransferScene: View {
    let isAnimated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = true

    var body: some View {
        Group {
            if !isAnimated || reduceMotion {
                TransferSceneFrame(step: WhatsNewTransferLoop.stillStep)
            } else if isOnScreen {
                TransferSceneLoop()
            } else {
                // Off screen: the loop stops on its first frame and starts
                // again from there, without a jump.
                TransferSceneFrame(step: .start)
            }
        }
        .onScreenChange(isAnimated: isAnimated) { isOnScreen = $0 }
    }
}

/// The loop: one redraw at each step's begin, then that step's animation.
/// It ends when the sheet closes.
private struct TransferSceneLoop: View {
    @State private var start = Date.now

    var body: some View {
        TimelineView(SceneLoopSchedule(
            start: start,
            begins: WhatsNewTransferLoop.Step.allCases.map(WhatsNewTransferLoop.begin(of:)),
            cycle: WhatsNewTransferLoop.cycleDuration
        )) { context in
            let step = WhatsNewTransferLoop.step(at: context.date.timeIntervalSince(start))
            TransferSceneFrame(step: step)
                .animation(WhatsNewTransferLoop.animation(to: step), value: step)
        }
    }
}

/// The dates a loop's steps begin, cycle after cycle.
private struct SceneLoopSchedule: TimelineSchedule {
    let start: Date
    /// Each step's begin, from the start of a cycle, in order.
    let begins: [Double]
    let cycle: Double

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let cyclesDone = (max(0, startDate.timeIntervalSince(start)) / cycle).rounded(.down)
        var cycleStart = start.addingTimeInterval(cyclesDone * cycle)
        var index = 0
        return AnyIterator {
            let date = cycleStart.addingTimeInterval(begins[index])
            index += 1
            if index == begins.count {
                index = 0
                cycleStart = cycleStart.addingTimeInterval(cycle)
            }
            return date
        }
    }
}

private extension View {
    /// iOS 18 and later: reports when the card scrolls off screen and back.
    /// On iOS 17 the loop runs while the sheet is open.
    @ViewBuilder
    func onScreenChange(isAnimated: Bool, _ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *), isAnimated {
            onScrollVisibilityChange(threshold: 0.01, action)
        } else {
            self
        }
    }
}

/// One frame of the Transfer picture.
private struct TransferSceneFrame: View {
    let step: WhatsNewTransferLoop.Step

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                row(
                    name: String(localized: "Everyday Spending", comment: "What's New picture: a sample wallet name"),
                    emoji: "\u{1F4B0}",
                    balance: WhatsNewTransferLoop.fromBalance(at: step),
                    address: SceneSample.address("4AdUndXH", "5ZDxJ8Bq"),
                    isActive: true
                )
                row(
                    name: String(localized: "Long-Term Savings Wallet", comment: "What's New picture: a sample wallet name"),
                    emoji: "\u{1F3D4}\u{FE0F}",
                    balance: WhatsNewTransferLoop.toBalance(at: step),
                    address: SceneSample.address("86yLe8Lm", "QHv5ezC1"),
                    isActive: false
                )
            }
            // Across the gap between From and To.
            .overlay {
                let shows = WhatsNewTransferLoop.showsAmount(at: step)
                SceneTransferAmount(amount: WhatsNewTransferLoop.amount)
                    .scaleEffect(shows ? 1 : 0.8)
                    .opacity(shows ? 1 : 0)
            }

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
            .scaleEffect(WhatsNewTransferLoop.buttonScale(at: step))
        }
        .opacity(WhatsNewTransferLoop.pictureOpacity(at: step))
    }

    /// A balance rolls in the direction it changes. Back at the start the
    /// picture is clear, so the balances swap at once.
    private func row(name: String, emoji: String, balance: Decimal, address: String, isActive: Bool) -> some View {
        SceneWalletRow(name: name, emoji: emoji, balance: balance, address: address, isActive: isActive)
            .contentTransition(step == .start
                ? .identity
                : .numericText(value: NSDecimalNumber(decimal: balance).doubleValue))
    }
}

/// The amount on its way from From to To: a brand chip on the part fill,
/// in fiat with Fiat Mode, as the rows.
private struct SceneTransferAmount: View {
    let amount: Decimal
    @EnvironmentObject private var priceService: PriceService

    private var text: String {
        if priceService.showFiatFirst, let fiat = priceService.formatFiatValue(amount) { return fiat }
        return "\(XMRFormatter.format(amount)) XMR"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.brand)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.brand.opacity(0.15), in: Capsule())
        .background(WhatsNewSceneColor.part, in: Capsule())
        .sceneShadow()
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

/// The envelope's loop: the real send (`PaymentLinkSendHero`, its beats
/// from 1.10 to 3.10, at its pace, with its springs and curves), without
/// the success check. The note; the open envelope comes up around it; the
/// note slides in; the flap folds down and the envelope lifts to the
/// middle. Then the stamp: a drop of wax, the stamp comes in, presses the
/// seal on and lifts away; one light sweep shows the amount in foil. A rest
/// on the sealed envelope, then the picture fades out and comes back at the
/// start. No haptics.
enum WhatsNewLinkLoop {
    enum Step: CaseIterable {
        /// The note alone, where the send's check turns into it. It fades
        /// back in.
        case start
        /// The open envelope comes up around the note.
        case arrive
        /// The note slides into the envelope.
        case noteIn
        /// The flap folds down; the envelope lifts to the middle.
        case close
        /// The flap passes 90 degrees: its outside shows.
        case flapOver
        /// A plain drop of wax.
        case drop
        /// The stamp comes in from the upper right and hovers over the wax.
        case hover
        /// It presses in.
        case press
        /// It meets the wax: the wax spreads.
        case contact
        /// It lifts.
        case lift
        /// The ring and the mark show in the wax.
        case mark
        /// It goes up and to the right, and fades.
        case away
        /// One light sweep: the foil shows where it has passed.
        case sweep
        /// The picture fades out, so everything goes back unseen.
        case fade
    }

    /// The frame that stands still with Reduce Motion: the sealed envelope
    /// with its foil, the last frame before the fade.
    static let stillStep: Step = .sweep

    /// The fade out and back in (crossFade).
    static let fadeDuration = 0.35
    /// The rest on the note before the envelope comes up.
    static let restOnNote = 0.6
    /// The hero's light sweep. Its time is not paced.
    static let sweepDuration = 1.2
    /// The rest on the sealed envelope before the fade.
    static let restOnResult = 2.0
    /// The hero's wax starts at this scale.
    static let dropStartScale: CGFloat = 0.3
    /// The hero's places, in the envelope's units: the open envelope sits
    /// this much lower than the sealed one, and comes up from this much
    /// lower again.
    static let openDrop: CGFloat = PaymentLinkSendHero.drop / PaymentLinkSendHero.unit
    static let arrival: CGFloat = PaymentLinkSendHero.arrival / PaymentLinkSendHero.unit

    /// The time from the begin of the step before to the begin of `step`:
    /// the fade-in and a rest, the hero's beats (its times at pace 1, times
    /// its pace), then the sweep and a rest.
    static func wait(before step: Step) -> Double {
        let pace = PaymentLinkSendHero.pace
        return switch step {
        case .start: 0
        case .arrive: fadeDuration + restOnNote
        case .noteIn: 0.3 * pace
        case .close: 0.35 * pace
        case .flapOver: 0.12 * pace
        case .drop: 0.23 * pace
        case .hover: 0.15 * pace
        case .press: 0.4 * pace
        case .contact: 0.09 * pace
        case .lift: 0.16 * pace
        case .mark: 0.03 * pace
        case .away: 0.07 * pace
        case .sweep: 0.1 * pace
        case .fade: sweepDuration + restOnResult
        }
    }

    /// When `step` begins, from the start of a cycle.
    static func begin(of step: Step) -> Double {
        var time = 0.0
        for earlier in Step.allCases {
            time += wait(before: earlier)
            if earlier == step { break }
        }
        return time
    }

    /// One cycle, rests included: it ends when the fade has finished.
    static var cycleDuration: Double {
        begin(of: .fade) + fadeDuration
    }

    /// The step shown `elapsed` seconds after the loop began. A time on a
    /// step's begin shows that step.
    static func step(at elapsed: Double) -> Step {
        let time = (max(0, elapsed) + 1e-6).truncatingRemainder(dividingBy: cycleDuration)
        return Step.allCases.last { begin(of: $0) <= time } ?? .start
    }

    /// The values of the hero's animated parts, in the envelope's units.
    /// The defaults are the start.
    struct Frame: Equatable {
        /// The note's place in the envelope, and the place of its layer.
        var noteShift: CGFloat = -Envelope.cardRise
        var noteY: CGFloat = WhatsNewLinkLoop.openDrop
        var envelopeShown: Double = 0
        var envelopeY: CGFloat = WhatsNewLinkLoop.openDrop + WhatsNewLinkLoop.arrival
        var flapAngle: Double = 180
        var flapLifted = true
        var sealShown: Double = 0
        var sealScale: CGFloat = WhatsNewLinkLoop.dropStartScale
        var sealMark: Double = 0
        var sealDome: Double = 1
        var toolShown: Double = 0
        var toolOffset: CGSize = PaymentLinkSendHero.toolAway
        var toolTilt: Double = PaymentLinkSendHero.toolTilt
        var toolHeight: CGFloat = 1
        var sweep: CGFloat = Envelope.sweepStart
        var opacity: Double = 1
    }

    /// The frame once the moves up to `step` have finished: each step sets
    /// what the hero sets at that beat.
    static func frame(at step: Step) -> Frame {
        let hero = PaymentLinkSendHero.self
        var frame = Frame()
        for move in Step.allCases {
            switch move {
            case .start:
                break
            case .arrive:
                frame.envelopeShown = 1
                frame.envelopeY = openDrop
            case .noteIn:
                frame.noteShift = 0
            case .close:
                frame.flapAngle = 0
                frame.envelopeY = 0
                frame.noteY = 0
            case .flapOver:
                frame.flapLifted = false
            case .drop:
                frame.sealShown = 1
                frame.sealScale = hero.dropScale
            case .hover:
                frame.toolShown = 1
                frame.toolOffset = CGSize(width: 0, height: hero.toolHover)
                frame.toolTilt = 0
            case .press:
                frame.toolOffset.height = hero.toolSink
                frame.toolHeight = 0
            case .contact:
                frame.sealScale = 1
                frame.sealDome = 0
            case .lift:
                frame.toolOffset.height = hero.toolSink - hero.toolLift
                frame.toolHeight = 1
            case .mark:
                frame.sealMark = 1
            case .away:
                frame.toolShown = 0
                frame.toolOffset = hero.toolAway
                frame.toolTilt = hero.toolTilt
            case .sweep:
                frame.sweep = Envelope.sweepEnd
            case .fade:
                frame.opacity = 0
            }
            if move == step { break }
        }
        return frame
    }
}

/// The envelope of the Link ready step with "0.5000 XMR" in foil, 178 pt
/// wide, with room above and below for the note, the open envelope and the
/// stamp. On its card it plays the send's loop; with Reduce Motion it
/// shows the sealed envelope, still.
struct LinkScene: View {
    static let width: CGFloat = 178
    /// Room above and below the sealed envelope (its units). The note rises
    /// 145 above the sealed envelope's top and the open envelope's bottom
    /// sits 178 below its bottom (the hero's places): with this room they
    /// stay inside the card, and the sealed envelope stays in the middle.
    static let headroom: CGFloat = 140

    let isAnimated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = true

    var body: some View {
        Group {
            if !isAnimated || reduceMotion {
                LinkSceneFrame(frame: WhatsNewLinkLoop.frame(at: WhatsNewLinkLoop.stillStep))
            } else if isOnScreen {
                LinkSceneLoop()
            } else {
                // Off screen: the loop stops on its first frame and starts
                // again from there, without a jump.
                LinkSceneFrame(frame: WhatsNewLinkLoop.frame(at: .start))
            }
        }
        .onScreenChange(isAnimated: isAnimated) { isOnScreen = $0 }
    }
}

/// The loop: one redraw at each step's begin. It ends when the sheet
/// closes.
private struct LinkSceneLoop: View {
    @State private var start = Date.now

    var body: some View {
        TimelineView(SceneLoopSchedule(
            start: start,
            begins: WhatsNewLinkLoop.Step.allCases.map(WhatsNewLinkLoop.begin(of:)),
            cycle: WhatsNewLinkLoop.cycleDuration
        )) { context in
            LinkSceneStamp(step: WhatsNewLinkLoop.step(at: context.date.timeIntervalSince(start)))
        }
    }
}

/// Moves to each step as the hero's `play()` does: each part with the
/// hero's own curve, at its pace.
private struct LinkSceneStamp: View {
    let step: WhatsNewLinkLoop.Step
    @State private var noteShift = WhatsNewLinkLoop.Frame().noteShift
    @State private var noteY = WhatsNewLinkLoop.Frame().noteY
    @State private var envelopeShown = WhatsNewLinkLoop.Frame().envelopeShown
    @State private var envelopeY = WhatsNewLinkLoop.Frame().envelopeY
    @State private var flapAngle = WhatsNewLinkLoop.Frame().flapAngle
    @State private var flapLifted = WhatsNewLinkLoop.Frame().flapLifted
    @State private var sealShown = WhatsNewLinkLoop.Frame().sealShown
    @State private var sealScale = WhatsNewLinkLoop.Frame().sealScale
    @State private var sealMark = WhatsNewLinkLoop.Frame().sealMark
    @State private var sealDome = WhatsNewLinkLoop.Frame().sealDome
    @State private var toolShown = WhatsNewLinkLoop.Frame().toolShown
    @State private var toolOffset = WhatsNewLinkLoop.Frame().toolOffset
    @State private var toolTilt = WhatsNewLinkLoop.Frame().toolTilt
    @State private var toolHeight = WhatsNewLinkLoop.Frame().toolHeight
    @State private var sweep = WhatsNewLinkLoop.Frame().sweep
    @State private var opacity = WhatsNewLinkLoop.Frame().opacity

    var body: some View {
        LinkSceneFrame(frame: WhatsNewLinkLoop.Frame(
            noteShift: noteShift,
            noteY: noteY,
            envelopeShown: envelopeShown,
            envelopeY: envelopeY,
            flapAngle: flapAngle,
            flapLifted: flapLifted,
            sealShown: sealShown,
            sealScale: sealScale,
            sealMark: sealMark,
            sealDome: sealDome,
            toolShown: toolShown,
            toolOffset: toolOffset,
            toolTilt: toolTilt,
            toolHeight: toolHeight,
            sweep: sweep,
            opacity: opacity
        ))
        .onChange(of: step) { _, step in show(step) }
    }

    private func show(_ step: WhatsNewLinkLoop.Step) {
        let hero = PaymentLinkSendHero.self
        let target = WhatsNewLinkLoop.frame(at: step)
        switch step {
        case .start, .fade:
            withAnimation(.easeInOut(duration: WhatsNewLinkLoop.fadeDuration)) { opacity = target.opacity }
        case .arrive:
            paced(.easeOut(duration: 0.3)) { envelopeShown = target.envelopeShown }
            paced(hero.settle) { envelopeY = target.envelopeY }
        case .noteIn:
            paced(hero.settle) { noteShift = target.noteShift }
        case .close:
            paced(hero.stepBack) {
                flapAngle = target.flapAngle
                envelopeY = target.envelopeY
                noteY = target.noteY
            }
        case .flapOver:
            // At once, as in the hero.
            flapLifted = target.flapLifted
        case .drop:
            paced(.linear(duration: 0.09)) { sealShown = target.sealShown }
            paced(hero.settle) { sealScale = target.sealScale }
        case .hover:
            paced(.linear(duration: 0.15)) { toolShown = target.toolShown }
            paced(hero.stepBack) {
                toolOffset = target.toolOffset
                toolTilt = target.toolTilt
            }
        case .press, .lift:
            paced(.easeIn(duration: 0.1)) {
                toolOffset = target.toolOffset
                toolHeight = target.toolHeight
            }
        case .contact:
            paced(.easeOut(duration: 0.16)) {
                sealScale = target.sealScale
                sealDome = target.sealDome
            }
        case .mark:
            paced(.easeOut(duration: 0.12)) { sealMark = target.sealMark }
        case .away:
            paced(hero.stepBack) {
                toolOffset = target.toolOffset
                toolTilt = target.toolTilt
            }
            paced(.easeIn(duration: 0.25)) { toolShown = target.toolShown }
        case .sweep:
            withAnimation(.easeInOut(duration: WhatsNewLinkLoop.sweepDuration)) { sweep = target.sweep }
        }
        catchUp(to: target)
    }

    /// At once: the parts that go back while the picture is clear, and any
    /// part a skipped step left behind (after the app was in the
    /// background). A part already on its way there is left alone.
    private func catchUp(to target: WhatsNewLinkLoop.Frame) {
        if noteShift != target.noteShift { noteShift = target.noteShift }
        if noteY != target.noteY { noteY = target.noteY }
        if envelopeShown != target.envelopeShown { envelopeShown = target.envelopeShown }
        if envelopeY != target.envelopeY { envelopeY = target.envelopeY }
        if flapAngle != target.flapAngle { flapAngle = target.flapAngle }
        if flapLifted != target.flapLifted { flapLifted = target.flapLifted }
        if sealShown != target.sealShown { sealShown = target.sealShown }
        if sealScale != target.sealScale { sealScale = target.sealScale }
        if sealMark != target.sealMark { sealMark = target.sealMark }
        if sealDome != target.sealDome { sealDome = target.sealDome }
        if toolShown != target.toolShown { toolShown = target.toolShown }
        if toolOffset != target.toolOffset { toolOffset = target.toolOffset }
        if toolTilt != target.toolTilt { toolTilt = target.toolTilt }
        if toolHeight != target.toolHeight { toolHeight = target.toolHeight }
        if sweep != target.sweep { sweep = target.sweep }
        if opacity != target.opacity { opacity = target.opacity }
    }

    /// An animation of the hero's `play()`, at its pace.
    private func paced(_ animation: Animation, _ body: () -> Void) {
        withAnimation(animation.speed(1 / PaymentLinkSendHero.pace), body)
    }
}

/// One frame of the envelope picture, in the envelope's units, drawn as the
/// hero draws it: the envelope's back, the note in its pocket mask, the
/// front with its seal and foil, and the stamp placed on the seal. The
/// layers sit on a tall canvas, so the note, the open flap and the rising
/// envelope always draw inside it; the layout keeps only the sealed
/// envelope and its headroom.
private struct LinkSceneFrame: View {
    let frame: WhatsNewLinkLoop.Frame
    private static let unit: CGFloat = LinkScene.width / Envelope.width
    /// The canvas's room above and below the sealed envelope: more than the
    /// envelope's rise (`openDrop` + `arrival`) and its shadow.
    private static let reach: CGFloat = 420
    private static let canvasHeight = Envelope.height + 2 * reach

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                layer(EnvelopeBack(flapAngle: frame.flapAngle, flapLifted: frame.flapLifted), y: frame.envelopeY)
                    .opacity(frame.envelopeShown)
                layer(note, y: frame.noteY)
                    .mask(alignment: .topLeading) { pocketMask }
                layer(front, y: frame.envelopeY)
                    .opacity(frame.envelopeShown)
            }
            // One layer, so the fades never show the back or the note
            // through the front.
            .compositingGroup()
            tool
        }
        .frame(width: Envelope.width, height: Self.canvasHeight, alignment: .topLeading)
        .scaleEffect(Self.unit, anchor: .topLeading)
        .frame(width: Envelope.width * Self.unit, height: Self.canvasHeight * Self.unit, alignment: .topLeading)
        // The layout: the sealed envelope and its headroom. The canvas
        // reaches past it evenly above and below.
        .frame(height: (Envelope.height + 2 * LinkScene.headroom) * Self.unit)
        .opacity(frame.opacity)
    }

    /// While the pocket fades in, the note below its edge fades out at the
    /// same rate, so the note never shows through the pocket (the hero's
    /// `pocketMask`).
    private var pocketMask: some View {
        VStack(spacing: 0) {
            Rectangle()
                .frame(height: Self.reach + frame.envelopeY)
            Rectangle()
                .opacity(1 - frame.envelopeShown)
        }
        .frame(width: Envelope.width, height: Self.canvasHeight, alignment: .top)
    }

    private var note: some View {
        EnvelopePaperCard(amount: EnvelopeCardAmount(text: "0.5000", showsUnit: true), sweep: frame.sweep)
            .offset(x: Envelope.cardOrigin.x, y: Envelope.cardOrigin.y + frame.noteShift)
    }

    private var front: some View {
        EnvelopeFront(
            flapAngle: frame.flapAngle,
            flapLifted: frame.flapLifted,
            sweep: frame.sweep,
            sealOpacity: frame.sealShown,
            sealScale: frame.sealScale,
            sealMark: frame.sealMark,
            sealDome: frame.sealDome
        ) {
            PaymentLinkCardFoil(amount: PaymentLinkCard.foil("0.5000", showsUnit: true), showsUnit: true)
                .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
                .mask(alignment: .topLeading) { EnvelopeFoilReveal(sweep: frame.sweep) }
        }
    }

    /// The stamp, its face's middle on the seal's middle, moved by the
    /// frame's offset and tilted about that point (the hero's `tool`).
    private var tool: some View {
        let size = EnvelopeStampTool.size
        let contact = EnvelopeStampTool.contact
        let seal = PaymentLinkSendHero.sealCenter
        return EnvelopeStampTool(height: frame.toolHeight)
            .rotationEffect(.degrees(frame.toolTilt), anchor: UnitPoint(x: contact.x / size.width, y: contact.y / size.height))
            .offset(x: frame.toolOffset.width, y: frame.toolOffset.height)
            .offset(x: seal.x - contact.x, y: Self.reach + frame.envelopeY + seal.y - contact.y)
            .opacity(frame.toolShown)
    }

    /// One layer of the envelope at `y` below the sealed envelope's place,
    /// on the canvas (the hero's `layer`).
    private func layer(_ content: some View, y: CGFloat) -> some View {
        content
            .frame(width: Envelope.width, height: Envelope.height, alignment: .topLeading)
            .offset(y: Self.reach + y)
            .frame(width: Envelope.width, height: Self.canvasHeight, alignment: .topLeading)
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
