import Foundation

/// Whether a meeting's transcript covers what was said in it, asked at the
/// stop and before any of its audio is let go (ADR 0048). A transcript that
/// says `complete` and is empty, thin or cut short is a hollow transcript,
/// and the bar is zero of them.
///
/// It is told what the transcriber knows: per side, the speech it cut into
/// stretches, how much of that it read, and the words the side came to.
/// And one thing the audio says on its own, from the spool and not through
/// the transcriber: how long the far side was louder than the silence
/// floor. That one catches a transcriber that was never fed at all.
enum CoverageCheck {
    struct Side: Equatable, Sendable {
        /// Speech the transcriber cut into stretches, the far side's copies
        /// on the mic it let go not counted, and how much of that the engine
        /// read. nil for a transcriber that keeps no count: the side is
        /// judged on its words alone.
        var speech: Duration?
        var read: Duration?
        /// What the side's turns came to, counted the way the file counts.
        var words: Int
    }

    enum Verdict: Equatable, Sendable {
        case pass
        /// The reason is the front matter's, in plain words.
        case thin(reason: String)
    }

    // Provisional, all of them (ADR 0048): reasoned from how people talk,
    // not tuned against a real meeting yet. Every result goes in the
    // meeting record, with the numbers it was reached from, so they can be.

    /// A side with less speech than this is a cough and a "yes": too little
    /// to hold a share of it against the transcript.
    static let enoughSpeechToJudge = Duration.seconds(10)
    /// The most of a side's speech that may go unread — stretches the
    /// engine failed twice, or that were still waiting when it was never
    /// there to read them — before the transcript does not cover it.
    static let mostUnread = 0.2
    /// A side read for less than this is a few short answers, and a few
    /// short answers can be "yeah", "mm", "right".
    static let enoughReadToCount = Duration.seconds(30)
    /// Talk runs at two or three words a second. Read speech that came to
    /// under half a word a second was heard and mostly not written down.
    static let fewestWordsPerSecond = 0.5

    static let couldNotBeRead = "some of what was said could not be read"
    static let fewerWords = "far fewer words than the talk that was heard"

    static func verdict(you: Side, them: Side, farSideLoud: Duration) -> Verdict {
        for side in [you, them] {
            guard let speech = side.speech, let read = side.read,
                  speech >= enoughSpeechToJudge
            else { continue }
            if (speech - read) / speech > mostUnread {
                return .thin(reason: couldNotBeRead)
            }
        }
        for side in [you, them] {
            guard let read = side.read, read >= enoughReadToCount else { continue }
            if Double(side.words) / read.totalSeconds < fewestWordsPerSecond {
                return .thin(reason: fewerWords)
            }
        }
        return .pass
    }
}
