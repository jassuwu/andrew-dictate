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

    /// above the measured worst case by a wide margin, because there is no
    /// transcription timeout anywhere else in the app.
    static let patience: TimeInterval = 3

    static func response(transcribingFor elapsed: TimeInterval) -> Response {
        elapsed < patience ? .refuseAndSayWhy : .dropAndRestart
    }
}
