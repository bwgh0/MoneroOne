import SwiftUI

struct SendStatusStep: View {
    let phase: SendFlowPhase
    let amountString: String
    let priceService: PriceService
    let onDone: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void
    var canRetry = true
    /// Link mode: while it sends, the Link ready text and buttons hold
    /// their places, unseen, so the spinner turns where the check lands.
    var reservesLinkReady = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showContent = false
    @State private var copiedHash = false
    /// Success: how many of "Sent!", the hash pill and Done have arrived.
    @State private var successArrived = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            if showsAmount {
                amountHeader
            }

            statusVisual
                .frame(height: 160)

            statusText

            Spacer()

            actionButtons
                .padding(.horizontal)
                .padding(.bottom)
        }
        .padding()
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                showContent = true
            }
        }
        .onChange(of: phase) { _ in
            // Reset and re-animate text when transitioning (e.g. sending → error)
            showContent = false
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                showContent = true
            }
        }
        .task(id: phase) { await arriveSuccessText() }
    }

    // MARK: - Amount

    private var showsAmount: Bool {
        switch phase {
        case .sending, .success: return amount != nil
        default: return false
        }
    }

    private var amount: Decimal? { Decimal(string: amountString) }

    private var figures: SendAmountFigures? {
        amount.map { SendAmountFigures(amount: $0, priceService: priceService) }
    }

    @ViewBuilder
    private var amountHeader: some View {
        if let figures {
            SendAmountHeader(figures: figures)
        }
    }

    // MARK: - Status visual

    private var statusVisual: some View {
        ZStack {
            switch phase {
            case .sending:
                GradientSpinner()
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5).combined(with: .opacity),
                        removal: .opacity.animation(.easeInOut(duration: 0.35))
                    ))

            case .success:
                SendSuccessMark {
                    HapticFeedback.shared.transactionSuccess()
                    SoundFeedback.shared.playSendComplete()
                }
                .transition(.identity)

            case .error:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.red)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))

            default:
                EmptyView()
            }
        }
    }

    // MARK: - Status text

    private var statusText: some View {
        ZStack(alignment: .top) {
            switch phase {
            case .sending:
                SendingStatusText()
                    .opacity(showContent ? 1 : 0)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                if reservesLinkReady {
                    PaymentLinkReadyText(figures: figures)
                        .hidden()
                }

            case .success(let txHash):
                successText(txHash: txHash)

            case .error(let message):
                errorText(message: message)
                    .opacity(showContent ? 1 : 0)

            default:
                EmptyView()
            }
        }
    }

    private func successText(txHash: String) -> some View {
        VStack(spacing: 12) {
            Text("Sent!")
                .font(.title.weight(.bold))
                .foregroundStyle(.green)
                .modifier(SendArrive(isShown: successArrived >= 1, reduceMotion: reduceMotion))

            hashPill(txHash: txHash)
                .modifier(SendArrive(isShown: successArrived >= 2, reduceMotion: reduceMotion))
        }
        .transition(.identity)
    }

    private func hashPill(txHash: String) -> some View {
        Button {
            UIPasteboard.general.string = txHash
            copiedHash = true
            HapticFeedback.shared.softTick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copiedHash = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copiedHash ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                Text(copiedHash ? "Copied!" : formatHash(txHash))
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(copiedHash ? .green : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .accessibilityLabel(copiedHash ? "Transaction ID copied" : "Copy transaction ID")
        .accessibilityHint("Copies the full transaction ID to clipboard")
    }

    private func errorText(message: String) -> some View {
        VStack(spacing: 12) {
            Text("Transaction Failed")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            switch phase {
            case .sending:
                if reservesLinkReady {
                    PaymentLinkReadyActions(record: nil)
                        .hidden()
                }

            case .success:
                Button(action: onDone) {
                    Text("Done")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .glassButtonStyle()
                .accessibilityLabel("Done")
                .modifier(SendArrive(isShown: successArrived >= 3, reduceMotion: reduceMotion))

            case .error:
                errorButtons

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var errorButtons: some View {
        if canRetry {
            Button(action: onRetry) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .glassButtonStyle()
            .accessibilityLabel("Retry transaction")
        }

        Button(action: onClose) {
            Text("Close")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .accessibilityLabel("Close")
    }

    // MARK: - Motion

    /// Success: "Sent!" arrives as the check reaches its corner (0.5 s),
    /// then the hash pill (0.6 s) and Done (0.7 s), each with `arrive`.
    /// Reduce Motion: all three cross-fade in at once.
    private func arriveSuccessText() async {
        guard case .success = phase else {
            successArrived = 0
            return
        }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) { successArrived = 3 }
            return
        }
        // `arrive` is easeOut 0.4 s after a 0.1 s delay; each step waits
        // for its start, so the delay is in the sleep.
        let starts: [Double] = [0.5, 0.6, 0.7]
        var elapsed = 0.0
        for (index, start) in starts.enumerated() {
            do {
                try await Task.sleep(for: .seconds(start - elapsed))
            } catch {
                successArrived = 3
                return
            }
            elapsed = start
            withAnimation(.easeOut(duration: 0.4)) { successArrived = index + 1 }
        }
    }

    private func formatHash(_ hash: String) -> String {
        ReceiveAddressLogic.shortAddress(hash)
    }
}

/// `arrive` for the Sent text: fade in and rise 20 pt. Reduce Motion: a
/// fade only.
private struct SendArrive: ViewModifier {
    let isShown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 20)
    }
}

/// The amount on the sending step. Fiat Mode puts the fiat amount on top,
/// as the balance card does; the other unit goes under it.
struct SendAmountFigures: Equatable {
    let hero: String
    /// "XMR" follows the hero amount; a fiat amount has none.
    let showsUnit: Bool
    let secondary: String?

    @MainActor
    init(amount: Decimal, priceService: PriceService) {
        let fiat = priceService.formatFiatValue(amount)
        if priceService.showFiatFirst, let fiat {
            hero = fiat
            showsUnit = false
            secondary = "\(XMRFormatter.format(amount)) XMR"
        } else {
            hero = XMRFormatter.format(amount)
            showsUnit = true
            secondary = fiat.map { "≈ \($0)" }
        }
    }
}

/// The 56 pt amount over the spinner, and the other unit under it.
struct SendAmountHeader: View {
    let figures: SendAmountFigures

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figures.hero)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)

                if figures.showsUnit {
                    Text("XMR")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let secondary = figures.secondary {
                Text(secondary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Sending Transaction..." and the line under it.
struct SendingStatusText: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Sending Transaction...")
                .font(.title2.weight(.semibold))

            Text("Please wait while your transaction is being broadcast")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
