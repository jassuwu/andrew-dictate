import Foundation

/// The sounds this app plays into a meeting to prove the tap hears, and how
/// long each lasts in the far side. The tap hears this process like any
/// other (ADR 0021), so each lands in `them` a moment after it is played:
/// proof the tap works, and nothing anyone said. A model handed one writes
/// it down as somebody speaking, so the transcriber is handed silence in its
/// place — for as long as the tone lasts and a little more, and no longer:
/// what the far side says around a tone is theirs to keep.
enum OurTones {
    /// The start sound, `dictation-start.wav`, played as a meeting starts
    /// and after every rebuild: 0.431 s. A test holds this to the file.
    static let startSound = Duration.milliseconds(432)
    /// The quiet probe: the third of a second of 1 kHz that
    /// `CoreAudioMeetingSource` plays when a far side gone quiet is asked
    /// whether it is still there.
    static let quietProbe = Duration.milliseconds(300)
    /// What a tone may land late by, from the moment it was asked for: the
    /// player starting, and the tap's own buffer. Provisional.
    static let margin = Duration.milliseconds(100)

    /// How much of the far side, from where a tone was asked for, is taken
    /// for that tone and silenced.
    static func silenced(for tone: Duration) -> Duration {
        tone + margin
    }

    /// How many of `chunk`'s far side samples, from its first, fall before
    /// `until`: the part of it that is a tone of ours.
    static func samples(of chunk: MeetingAudioChunk, before until: Duration) -> Int {
        guard chunk.at < until else { return 0 }
        let ours = Int(((until - chunk.at).totalSeconds * MeetingAudioChunk.sampleRate).rounded())
        return min(ours, chunk.them.count)
    }

    /// `samples` with the first `count` of them silent, the same length.
    static func silencing(_ samples: [Float], first count: Int) -> [Float] {
        let count = min(max(0, count), samples.count)
        guard count > 0 else { return samples }
        var silenced = samples
        silenced.replaceSubrange(0..<count, with: repeatElement(0, count: count))
        return silenced
    }
}
