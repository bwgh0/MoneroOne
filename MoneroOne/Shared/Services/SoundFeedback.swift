import AVFoundation
import UIKit

/// Short "send complete" chime, played once a transaction is broadcast.
///
/// The asset is our own synthesized `SendComplete` data asset: two ascending
/// bell notes, 0.85 s. Playback goes through an `.ambient` audio session, so
/// it respects the silent switch and mixes with music or a call instead of
/// interrupting them. Failures never reach the UI: a missing asset or a
/// session error just means no chime.
@MainActor
final class SoundFeedback {
    static let shared = SoundFeedback()

    /// UserDefaults key behind the Settings > Display > Sounds toggle.

    private let player: AVAudioPlayer?
    private var sessionActivated = false

    private init() {
        // Category first: a player prepared under the default `.soloAmbient`
        // would silence other audio the moment it touches the hardware.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)

        if let asset = NSDataAsset(name: "SendComplete"),
           let player = try? AVAudioPlayer(data: asset.data) {
            player.prepareToPlay()
            self.player = player
        } else {
            self.player = nil
        }
    }

    /// Play the chime. No-op when the asset did not load. The `.ambient`
    /// session already keeps it silent while the ringer switch is off.
    func playSendComplete() {
        guard let player else { return }
        if !sessionActivated {
            sessionActivated = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
        }
        player.currentTime = 0
        player.play()
    }
}
