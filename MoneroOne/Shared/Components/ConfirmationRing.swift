import SwiftUI

/// How full a transaction's confirmation ring is. A transaction is
/// spendable after 10 confirmations; the ring fills one tenth per block.
enum ConfirmationRing {
    static let target = 10

    enum State: Equatable {
        /// No ring: a failed transaction, or one whose confirmations are
        /// still loading.
        case hidden
        /// 0 to 9 confirmations: the ring's fill, 0...0.9.
        case filling(Double)
        /// 10 or more: no ring. A ring on screen closes first.
        case confirmed
    }

    /// A pool transaction with no count yet shows an empty ring.
    static func state(confirmations: Int?, isFailed: Bool, isPending: Bool) -> State {
        guard !isFailed else { return .hidden }
        guard let count = confirmations ?? (isPending ? 0 : nil) else { return .hidden }
        guard count < target else { return .confirmed }
        return .filling(Double(max(0, count)) / Double(target))
    }

    static func state(of transaction: MoneroTransaction) -> State {
        state(
            confirmations: transaction.confirmations,
            isFailed: transaction.status == .failed,
            isPending: transaction.status == .pending
        )
    }

    /// VoiceOver only: "3 of 10 confirmations" while the ring shows.
    static func spokenProgress(of transaction: MoneroTransaction) -> String? {
        guard case .filling(let fill) = state(of: transaction) else { return nil }
        let count = Int((fill * Double(target)).rounded())
        return String(
            localized: "\(count) of \(target) confirmations",
            comment: "VoiceOver, Activity row: confirmations so far of the 10 a transaction needs to be spendable"
        )
    }
}

/// The 40 pt direction disc of a transaction row. While a transaction has
/// fewer than 10 confirmations, a 2 pt ring on the disc's rim fills one
/// tenth per block (stepForward spring). At 10 the ring closes, the disc
/// turns green and the arrow becomes a tick (crossFade, 0.25 s in), then
/// all of it fades back to the plain disc (0.75 s in). No loops.
///
/// Reduce Motion: each step and the tick cross-fade (0.35 s).
struct TransactionDisc: View {
    let systemImage: String
    let tint: Color
    /// The transaction's ring (`ConfirmationRing.state`).
    let ringState: ConfirmationRing.State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: Double
    @State private var showsRing: Bool
    @State private var isComplete = false
    @State private var completionTask: Task<Void, Never>?

    static let size: CGFloat = 40

    /// A row that comes on screen shows its ring as it is, with no motion.
    init(systemImage: String, tint: Color, ringState: ConfirmationRing.State = .hidden) {
        self.systemImage = systemImage
        self.tint = tint
        self.ringState = ringState
        if case .filling(let fill) = ringState {
            _fill = State(initialValue: fill)
            _showsRing = State(initialValue: true)
        } else {
            _fill = State(initialValue: 0)
            _showsRing = State(initialValue: false)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(discColor.opacity(0.15))

            Image(systemName: isComplete ? "checkmark" : systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(discColor)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))

            ring
        }
        .frame(width: Self.size, height: Self.size)
        .animation(crossFade, value: isComplete)
        .onChange(of: ringState) { old, new in
            ringStateChanged(from: old, to: new)
        }
        .onDisappear {
            completionTask?.cancel()
        }
    }

    private var discColor: Color { isComplete ? .green : tint }

    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: 1)
                .stroke(Color(.secondarySystemFill), lineWidth: 2)

            Circle()
                .inset(by: 1)
                .trim(from: 0, to: fill)
                .stroke(isComplete ? Color.green : Color.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(step, value: fill)
        }
        .opacity(showsRing ? 1 : 0)
        .animation(crossFade, value: showsRing)
        .accessibilityHidden(true)
    }

    /// stepForward: spring(response 0.3, damping 0.85). Reduce Motion: crossFade.
    private var step: Animation {
        reduceMotion ? .easeInOut(duration: 0.35) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    /// crossFade: easeInOut 0.35 s.
    private var crossFade: Animation { .easeInOut(duration: 0.35) }

    private func ringStateChanged(from old: ConfirmationRing.State, to new: ConfirmationRing.State) {
        switch new {
        case .filling(let newFill):
            completionTask?.cancel()
            isComplete = false
            fill = newFill
            showsRing = true
        case .hidden:
            completionTask?.cancel()
            isComplete = false
            showsRing = false
        case .confirmed:
            // A ring on screen closes, turns green with a tick, then fades.
            guard case .filling = old, showsRing else {
                showsRing = false
                return
            }
            completionTask?.cancel()
            fill = 1
            completionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    isComplete = true
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                isComplete = false
                showsRing = false
            }
        }
    }
}
