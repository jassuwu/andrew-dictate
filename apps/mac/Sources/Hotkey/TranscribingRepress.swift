import Foundation

/// what a second press of the dictation key means while the last sentence is
/// still being written out. the name mirrors
/// `MeetingSession.DictationResponse`, which the sibling branch reads.
enum TranscribingRepress {
    enum Response: Equatable, Sendable {
        /// the sentence is nearly there — keep it, and say why the key is deaf
        case refuseAndSayWhy
        /// it has been long enough to be a hang; the key must not be wedged
        case dropAndRestart
    }

    /// above the measured worst case by a wide margin. a take the engine
    /// never answers also ends on its own deadline (`TranscriptionDeadline`),
    /// but that one runs longer for a long take, and a press this late
    /// doesn't wait for it.
    static let patience: TimeInterval = 3

    static func response(transcribingFor elapsed: TimeInterval) -> Response {
        elapsed < patience ? .refuseAndSayWhy : .dropAndRestart
    }
}
