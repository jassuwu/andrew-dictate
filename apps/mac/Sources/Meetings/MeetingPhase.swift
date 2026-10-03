import Foundation

/// What a meeting is doing, as the menu, the badge and the lamp read it:
/// one thing, worked out from what the coordinator already knows, so the
/// three can never tell it differently. `saved` is not one of them: it is
/// a moment, said on the lamp, and the menu's `show last meeting in finder`
/// row for ten minutes after.
enum MeetingPhase: Equatable, Sendable {
    /// No meeting, and nothing being written out.
    case idle
    /// From `record` until the model has loaded and the tap has heard its
    /// start sound, while either is still to come. The audio is kept from
    /// the start, so a stop now still keeps the words.
    case gettingReady
    /// Both are in: the meeting is being heard and read. A tap being
    /// rebuilt with no problem standing is still this; the lamp says the
    /// gap.
    case recording
    /// Something is wrong that the meeting records through: the worst of
    /// what stands.
    case problem(MeetingSession.Problem)
    /// A stopped meeting whose file is not on disk yet, or a spool a crash
    /// left, being written out at launch: then `recovering` names its app.
    case writingOut(recovering: String?)

    /// `problems` worst first, as the session keeps them. `writingOut` is
    /// a stopped meeting not yet on disk; `recovering` is the app of a
    /// spool being written out at launch, while it is. Whether the tap has
    /// heard its start sound is the session's: until it has, the state is
    /// `provingItCanHear`.
    init(
        state: MeetingSession.State,
        modelLoaded: Bool,
        problems: [MeetingSession.Problem],
        writingOut: Bool,
        recovering: String? = nil
    ) {
        switch state {
        // the meeting being recorded is the one shown, whatever an earlier
        // one is doing on its way to disk.
        case .provingItCanHear, .recording, .rebuilding:
            if let worst = problems.first {
                self = .problem(worst)
            } else if state == .provingItCanHear || !modelLoaded {
                self = .gettingReady
            } else {
                self = .recording
            }
        // never heard at the start: the meeting is ending, and the pill
        // says why.
        case .idle, .cannotHear:
            if writingOut {
                // the one you just stopped is the one you are waiting on.
                self = .writingOut(recovering: nil)
            } else if let recovering {
                self = .writingOut(recovering: recovering)
            } else {
                self = .idle
            }
        }
    }

    /// The phase in a few words, for the log.
    var logged: String {
        switch self {
        case .idle: "idle"
        case .gettingReady: "getting ready"
        case .recording: "recording"
        case .problem(let problem): "problem, \(MeetingEvent.problemBegan(problem).hudText ?? "")"
        case .writingOut(nil): "writing it out"
        case .writingOut(let app?): "writing out an unsaved \(app) recording"
        }
    }
}
