import Foundation

/// what each phase of a meeting looks like where it is shown (ticket 27):
/// the menu's first line, the badge's mark, what voiceover says for it,
/// and the lamp's facts. all four read the one phase the coordinator
/// publishes, so none can tell the meeting differently from the others.
extension MeetingPhase {
    /// the first line of the menu, or nil with no meeting to say. after a
    /// save it is nil, and `show last meeting in finder` leads instead.
    func menuLine(elapsed: Duration) -> String? {
        switch self {
        case .idle: nil
        case .gettingReady: "getting ready…"
        case .recording: "recording · \(elapsed.runningClock)"
        // in the words the lamp said when it began, until it clears.
        case .problem(let problem): MeetingEvent.problemBegan(problem).hudText
        case .writingOut(nil): "writing it out…"
        case .writingOut(let app?): "writing out an unsaved \(app) recording…"
        }
    }

    /// what voiceover says for the badge, after the app's name: the mark
    /// carries the phase and nothing else.
    var spoken: String? {
        switch self {
        case .idle: nil
        case .gettingReady: "getting ready to record a meeting"
        case .recording: "recording a meeting"
        case .problem(let problem):
            "recording a meeting, \(MeetingEvent.problemBegan(problem).hudText ?? "")"
        case .writingOut(nil): "writing out a meeting"
        case .writingOut(let app?): "writing out an unsaved \(app) recording"
        }
    }
}

extension BadgeLook.Meeting {
    /// the meeting as the badge wears it. a call nobody records is shown
    /// only when there is no meeting: one being recorded or written out is
    /// the meeting the badge is about.
    init(_ phase: MeetingPhase, callNotRecorded: Bool) {
        switch phase {
        case .idle: self = callNotRecorded ? .callNotRecorded : .none
        case .gettingReady: self = .gettingReady
        case .recording: self = .recording
        case .problem: self = .problem
        // the file is not on disk yet, so the badge is still busy with a
        // meeting: the partial rim is the busy look it has. the full rim
        // would say the mic is still live, and the bare badge that the
        // meeting is done.
        case .writingOut: self = .gettingReady
        }
    }
}

extension HUDMeetingFacts {
    /// the lamp's side of the phase. a stopped meeting being written out,
    /// and a recovery, light nothing: the lamp cools out at the stop, and
    /// the pill says `writing it out…`.
    init(_ phase: MeetingPhase) {
        switch phase {
        case .idle, .writingOut: self.init()
        case .gettingReady: self.init(isRecording: true, isGettingReady: true)
        case .recording: self.init(isRecording: true)
        case .problem: self.init(isRecording: true, hasProblem: true)
        }
    }
}
