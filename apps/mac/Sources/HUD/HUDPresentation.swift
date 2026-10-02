import Foundation

/// the lamp's four moods as the panel needs them — its own enum, like
/// HUDContent, so the rule below can be argued with in tests without the
/// coordinator (and the speech engines behind it) coming along.
enum HUDLampState: Equatable, Sendable {
    case idle
    case prewarming
    case recording
    case transcribing
}

/// what a meeting shows on the lamp (ticket 28). its own looks, apart from
/// dictation's moods: a full-screen call hides the menu bar, and the lamp is
/// then the only sign a meeting is being recorded.
enum HUDMeetingLight: Equatable, Sendable {
    case off
    /// the dim ember a take wears before its mic is heard: the meeting has
    /// not proved it can hear yet.
    case ember
    /// recording: a low light that holds. it does not follow the voices in
    /// the room and it does not breathe, because it is on for two hours.
    case steady
    /// something is wrong with the meeting: the steady light in the
    /// attention colour. never gold, because gold means working.
    case problem
    /// the meeting stopped a moment ago: the lamp's own cool-out, the panel
    /// up until it has played, then nothing.
    case coolingOut
}

/// the meeting's side of the lamp, as plain facts. the last two are set by
/// nothing yet: their looks are built so whoever has a reason to set them
/// need not touch the drawing.
struct HUDMeetingFacts: Equatable, Sendable {
    /// from `record` until the meeting stops.
    var isRecording = false
    /// its first moments: the tap has not heard the start sound yet.
    var isProvingItCanHear = false
    /// a meeting is getting ready to record.
    var isGettingReady = false
    /// something is wrong with the meeting that is on.
    var hasProblem = false
}

/// what the stage holds. one thing at a time: a pill outranks a lamp, and
/// dictation's lamp outranks a meeting's.
enum HUDStage: Equatable, Sendable {
    case nothing
    case pill
    case dictation
    case meeting(HUDMeetingLight)
}

/// whether the panel is on screen at all, in one pure function: the rule
/// was three guards in a row, and "nothing glows until you ask" was the
/// one it did not have.
enum HUDPresentation {
    static func shouldPresent(
        state: HUDLampState,
        hasFeedback: Bool,
        isOnboarding: Bool,
        prewarmPresentsHUD: Bool,
        meetingLight: HUDMeetingLight = .off
    ) -> Bool {
        stage(
            state: state,
            hasFeedback: hasFeedback,
            isOnboarding: isOnboarding,
            prewarmPresentsHUD: prewarmPresentsHUD,
            meetingLight: meetingLight
        ) != .nothing
    }

    /// what is on the stage; `shouldPresent` is whether anything is. a
    /// meeting's light has the lamp whenever dictation is not using it, and
    /// an unasked warm-up shows nothing of its own, so the meeting keeps the
    /// lamp through one.
    static func stage(
        state: HUDLampState,
        hasFeedback: Bool,
        isOnboarding: Bool,
        prewarmPresentsHUD: Bool,
        meetingLight: HUDMeetingLight
    ) -> HUDStage {
        // setup owns the screen while it is open. a message that would
        // have spoken over it is held, not lost (HUDFeedbackGate).
        guard !isOnboarding else {
            return .nothing
        }
        // exceptional messages always speak, warm-up or not.
        if hasFeedback {
            return .pill
        }

        switch state {
        case .idle:
            break
        case .prewarming:
            // the ember means "not ready for the key you just pressed", so
            // at login it means nothing: nobody pressed anything. the menu
            // carries "loading the speech model…" for whoever looks, which
            // is where unprompted status belongs (ADR 0030).
            if prewarmPresentsHUD {
                return .dictation
            }
        case .recording, .transcribing:
            return .dictation
        }
        return meetingLight == .off ? .nothing : .meeting(meetingLight)
    }

    /// the meeting's light, from the meeting's facts and the light it had.
    /// the facts cannot say the one thing `previous` can: that the light
    /// was on a moment ago and is still going out. `.coolingOut` holds
    /// until whoever timed the cool-out sets the light off.
    static func meetingLight(
        _ facts: HUDMeetingFacts,
        after previous: HUDMeetingLight = .off
    ) -> HUDMeetingLight {
        guard facts.isRecording || facts.isGettingReady else {
            return previous == .off ? .off : .coolingOut
        }
        if facts.hasProblem {
            return .problem
        }
        if facts.isGettingReady || facts.isProvingItCanHear {
            return .ember
        }
        return .steady
    }

    /// whether the panel is left out of every screen capture: a share, a
    /// recording, a screenshot. it is while a meeting is on or a pill about
    /// one is up, so the people on the call see neither. dictation's lamp
    /// and pills stay in, as they always were: a screenshot of one is how a
    /// bug report shows it. a panel on screen is never put back in, so a
    /// take that follows a meeting's pill cannot flicker into a share; it
    /// goes back in the next time the panel comes up.
    static func hidesFromCapture(
        meetingLight: HUDMeetingLight,
        meetingPillIsUp: Bool,
        isHiddenNow: Bool,
        isOnScreen: Bool
    ) -> Bool {
        if meetingLight != .off || meetingPillIsUp {
            return true
        }
        return isHiddenNow && isOnScreen
    }

    /// whether a question (a pill with a button, ADR 0047) may go up now.
    /// it waits for everything else: a take, a sentence, setup. an ember
    /// counts as busy even when it shows nothing, because the lamp settling
    /// back to idle clears the pill, and the question with it.
    static func pillIsFreeForAQuestion(
        state: HUDLampState,
        hasFeedback: Bool,
        isOnboarding: Bool
    ) -> Bool {
        state == .idle && !hasFeedback && !isOnboarding
    }
}
