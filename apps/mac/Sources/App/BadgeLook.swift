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
        self = .idle
    }
}
