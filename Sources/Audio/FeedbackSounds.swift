import AVFoundation

@MainActor
final class FeedbackSounds {
    enum Cue: Hashable {
        case start
        case end
    }

    private struct SoundKey: Hashable {
        let cue: Cue
        let mode: DictationMode
    }

    private let settings: AppSettings
    private var players: [SoundKey: AVAudioPlayer] = [:]

    init(
        settings: AppSettings = .shared,
        bundle: Bundle = .main
    ) {
        self.settings = settings

        for mode in DictationMode.allCases {
            for cue in [Cue.start, .end] {
                let key = SoundKey(cue: cue, mode: mode)
                let resourceName = "\(mode.rawValue)-\(cue.resourceSuffix)"

                guard let url = Self.soundURL(
                    named: resourceName,
                    in: bundle
                ) else {
                    print(
                        "feedback sound unavailable: "
                            + resourceName
                            + ".wav"
                    )
                    continue
                }

                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.volume = 0.55
                    player.prepareToPlay()
                    players[key] = player
                } catch {
                    print(
                        "feedback sound unavailable: "
                            + resourceName
                            + ".wav"
                    )
                }
            }
        }
    }

    func play(_ cue: Cue, for mode: DictationMode) {
        guard settings.soundFeedbackEnabled,
              let player = players[SoundKey(cue: cue, mode: mode)] else {
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
