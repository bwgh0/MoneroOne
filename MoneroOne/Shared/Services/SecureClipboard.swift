import UIKit
import UniformTypeIdentifiers

/// Clipboard writes for secret material — seed words, view keys.
///
/// Two properties an ordinary `UIPasteboard.general.string = secret` doesn't
/// give us:
///
/// - **OS-enforced expiry.** The app-side `DispatchQueue.asyncAfter` clear task
///   dies with the process, so force-quitting (or a jetsam kill) right after
///   copying used to leave the seed on the clipboard indefinitely. iOS honors
///   `.expirationDate` regardless of whether we're still running.
/// - **No Universal Clipboard.** Without `.localOnly` the seed is broadcast to
///   every nearby device signed into the same Apple ID.
enum SecureClipboard {
    /// Long enough to paste into a password manager, short enough to limit the
    /// window for other apps and keyboard extensions with full access.
    static let secretLifetime: TimeInterval = 45

    static func copySecret(_ value: String, lifetime: TimeInterval = secretLifetime) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime)
            ]
        )
    }

    /// Belt-and-braces in-app clear, for when the user is still around before
    /// the OS expiry fires. Only clears if the secret is still the current
    /// entry, so we never wipe something the user copied afterwards.
    static func clearIfHolding(_ value: String) {
        if UIPasteboard.general.string == value {
            UIPasteboard.general.items = []
        }
    }
}
