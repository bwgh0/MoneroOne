import UIKit

final class HapticFeedback {
    static let shared = HapticFeedback()

    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
    }

    /// Soft tick for keypad presses
    func softTick() {
        lightGenerator.impactOccurred(intensity: 0.6)
    }

    /// Medium feedback for navigation button taps
    func buttonPress() {
        mediumGenerator.impactOccurred(intensity: 0.7)
    }

    /// Heavy impact when confirming send
    func sendInitiated() {
        heavyGenerator.impactOccurred()
    }

    /// Apple Pay double-tap pattern on transaction success
    func transactionSuccess() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            generator.impactOccurred()
        }
    }

    /// Error notification feedback
    func error() {
        notificationGenerator.notificationOccurred(.error)
    }
}
