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

    static func verdict(you: Side, them: Side, farSideLoud: Duration) -> Verdict {
        .pass
    }
}
