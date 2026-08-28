import AVFoundation
import os

/// file scope because the cues load during init, before there is a `self`
/// to log through.
private let soundsLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)

@MainActor
final class FeedbackSounds {
    enum Cue: Hashable {
        case start
        case end
    }

    private let settings: AppSettings
    private var players: [Cue: AVAudioPlayer] = [:]

    init(
        settings: AppSettings = .shared,
        bundle: Bundle = .main
    ) {
        self.settings = settings

        for cue in [Cue.start, .end] {
            let resourceName = "dictation-\(cue.resourceSuffix)"

            guard let url = Self.soundURL(
                named: resourceName,
                in: bundle
            ) else {
                soundsLogger.error(
                    """
                    feedback sound missing: \
                    \(resourceName, privacy: .public).wav
                    """
                )
                continue
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = 0.55
                player.prepareToPlay()
                players[cue] = player
            } catch {
                soundsLogger.error(
                    """
                    feedback sound unavailable: \
                    \(resourceName, privacy: .public).wav: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    func play(_ cue: Cue) {
        guard settings.soundFeedbackEnabled,
              let player = players[cue] else {
            return
        }

        player.currentTime = 0
        player.play()
    }

    private static func soundURL(
        named name: String,
        in bundle: Bundle
    ) -> URL? {
        bundle.url(
            forResource: name,
            withExtension: "wav",
            subdirectory: "Sounds"
        ) ?? bundle.url(
            forResource: name,
            withExtension: "wav",
            subdirectory: "Resources/Sounds"
        ) ?? bundle.url(
            forResource: name,
            withExtension: "wav"
        )
    }
}

private extension FeedbackSounds.Cue {
    var resourceSuffix: String {
        switch self {
        case .start:
            "start"
        case .end:
            "end"
        }
    }
}
