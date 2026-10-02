import Foundation

/// What the pill asks about a meeting, with its one button, and what each
/// answer does (ADR 0047). The app suggests and never acts: the button does
/// exactly what the menu item of the same name does, and nothing else here
/// starts or stops a recording. A question nobody answers is over, and the
/// recording, or the lack of one, is as it was.
enum MeetingQuestion: Equatable, Sendable {
    /// A call began and nothing is recording it.
    case record(app: String)
    /// The call a recording was keeping ended, and the recording runs on.
    case stopAfterCall(app: String)
    /// The nudge: an hour with nothing heard. Asked in a notification too.
    case stillRecording

    init(_ suggestion: CallWatcher.Suggestion) {
        switch suggestion {
        case let .record(app): self = .record(app: app)
        case let .stop(app): self = .stopAfterCall(app: app)
        }
    }

    /// About a recording that is running, rather than one that could be:
    /// stopping the meeting, from anywhere, answers it.
    var isAboutARecording: Bool {
        switch self {
        case .record: false
        case .stopAfterCall, .stillRecording: true
        }
    }

    var text: String {
        switch self {
        case let .record(app): "\(app) call — record it?"
        case .stopAfterCall: "call ended — stop recording?"
        case .stillRecording: "still recording?"
        }
    }

    /// The menu item's own word, so the button and the menu are one action.
    var button: String {
        switch self {
        case .record: "record"
        case .stopAfterCall, .stillRecording: "stop"
        }
    }

    /// What VoiceOver calls the button: the whole action, not one word.
    var buttonLabel: String {
        switch self {
        case let .record(app): "record the \(app) call"
        case .stopAfterCall, .stillRecording: "stop recording"
        }
    }

    /// A call that just began is worth a glance, and after that the menu
    /// keeps it. A recording that may be running on for nobody is worth
    /// longer. Both are guesses until real calls tune them.
    var lasts: Duration {
        switch self {
        case .record: .seconds(15)
        case .stopAfterCall, .stillRecording: .seconds(30)
        }
    }

    enum Answer: Equatable, Sendable {
        /// The one button.
        case button
        /// A click on the pill beside the button.
        case elsewhere
        /// It ran out, or a take or a sentence took the pill.
        case unanswered
    }

    enum Effect: Equatable, Sendable {
        /// What `record a meeting` does, named after the call.
        case startMeeting(name: String)
        /// What `stop recording` does.
        case stopMeeting
        /// The nudge's `keep going`.
        case keepGoing
        /// No to recording this call: the watcher is told, and does not ask
        /// again until the next one.
        case declineTheCall
        case nothing
    }

    func effect(of answer: Answer) -> Effect {
        switch (self, answer) {
        case let (.record(app), .button): .startMeeting(name: app)
        case (.record, .elsewhere): .declineTheCall
        case (.stopAfterCall, .button), (.stillRecording, .button): .stopMeeting
        case (.stillRecording, .elsewhere): .keepGoing
        case (.stopAfterCall, .elsewhere), (_, .unanswered): .nothing
        }
    }
}
