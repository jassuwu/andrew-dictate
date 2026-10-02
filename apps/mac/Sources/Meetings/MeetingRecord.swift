import Foundation

/// how one meeting ended, and what the capture and the engine did on the
/// way there: the evidence a lost meeting or a hollow transcript leaves.
///
/// never any of the words. not what was said, not a file name that took its
/// name from it — counts and times are all a record knows about the talk,
/// which is what makes it safe to send to jass.
struct MeetingRecord: Equatable, Sendable {
    /// every way a meeting ends. a recovery is not one of them: it ends in
    /// one of these like any other, and `recovered` says the rest.
    enum Outcome: Equatable, Sendable {
        /// the transcript is on disk.
        case saved
    }

    var outcome: Outcome
    /// the app as shown to people: "zoom", "chrome".
    var app: String
    /// the meeting model, by the name the spool and the file use.
    var model: String
    /// wall-clock start, so a record can be matched to a report.
    var startedAt: Date
    /// seconds of the meeting, gaps included.
    var durationS: Double
}
