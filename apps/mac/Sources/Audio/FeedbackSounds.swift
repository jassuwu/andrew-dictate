import AVFoundation
import os

/// file scope because the cues load off the main actor, where there is no
/// `self` to log through.
private let soundsLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)

@MainActor
final class FeedbackSounds {
    enum Cue: Hashable, Sendable {
        case start
        case end
    }

    private let settings: AppSettings
    private let sounds: [Cue: URL]
    private var players: CuePlayers

    init(
        settings: AppSettings = .shared,
        bundle: Bundle = .main
    ) {
        self.settings = settings

        var sounds: [Cue: URL] = [:]
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
            sounds[cue] = url
        }
        self.sounds = sounds
        players = CuePlayers(sounds: sounds)
    }

    func play(_ cue: Cue) {
        guard settings.soundFeedbackEnabled else {
            return
        }

        players.play(cue)
    }

    /// the default output moved. players opened against the old one are
    /// left to whatever they are stuck in, and new ones open on a queue of
    /// their own.
    func outputChanged() {
        players = CuePlayers(sounds: sounds)
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

/// the cues' players and the queue they play on. an `AVAudioPlayer` opens
/// the output device when it prepares and when it plays, and that can block
/// on an output that is going away — a monitor's speakers mid-unplug — so
/// none of it happens on the main thread, and the players are only ever
/// touched on `queue`.
private final class CuePlayers: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).feedback-sounds",
        qos: .userInteractive
    )
    private var players: [FeedbackSounds.Cue: AVAudioPlayer] = [:]

    init(sounds: [FeedbackSounds.Cue: URL]) {
        queue.async { [self] in
            load(sounds)
        }
    }

    func play(_ cue: FeedbackSounds.Cue) {
        queue.async { [self] in
            guard let player = players[cue] else {
                return
            }
            player.currentTime = 0
            player.play()
        }
    }

    private func load(_ sounds: [FeedbackSounds.Cue: URL]) {
        for (cue, url) in sounds {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                // 8 dB under where it shipped: the same switch, further from the ear.
                // picked by ear against EQ'd variants (2026-09-21); the sound
                // itself stays untouched.
                player.volume = 0.22
                player.prepareToPlay()
                players[cue] = player
            } catch {
                soundsLogger.error(
                    """
                    feedback sound unavailable: \
                    \(url.lastPathComponent, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
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
