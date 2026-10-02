import Foundation

/// what the menu bar badge wears. its own enum, like HUDLampState, so the
/// order between a meeting, a take and a setup gap can be argued with in
/// tests without the coordinators (and the engines behind them) coming
/// along. BadgeMarks draws each one.
enum BadgeLook: Equatable, Sendable, CaseIterable {
    case idle
    case dictating
    /// a call app has the mic and nothing is recording it: you could still
    /// start late.
    case callNotRecorded
    /// a meeting was started and its model is still loading.
    case gettingReady
    case recordingMeeting
    case meetingProblem
    /// a missing grant or a speech model that never downloaded.
    case needsSetup

    /// the meeting as far as the badge cares.
    enum Meeting: Equatable, Sendable, CaseIterable {
        case none
        case callNotRecorded
        case gettingReady
        case recording
        case problem
    }

    init(needsSetup: Bool, isDictating: Bool, meeting: Meeting) {
        // a setup gap outranks every other state: a missing grant or a
        // speech model that never downloaded means the other states can
        // never be reached anyway.
        if needsSetup {
            self = .needsSetup
            return
        }

        switch meeting {
        // a problem stays until it clears, so it outranks a take that
        // started around it.
        case .problem:
            self = .meetingProblem
        // dictation is refused while a meeting records (ADR 0023), so a
        // take never shares the badge with one; if it ever did, the hour
        // long meeting is the one to show.
        case .recording:
            self = .recordingMeeting
        case .gettingReady:
            self = .gettingReady
        // a take is the mic live right now. a call nobody records is only
        // a chance to start one, and it is still there when the take ends.
        case .none,
             .callNotRecorded:
            self = isDictating ? .dictating : .idle
        }
    }
}
