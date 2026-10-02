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

/// whether the panel is on screen at all, in one pure function: the rule
/// was three guards in a row, and "nothing glows until you ask" was the
/// one it did not have.
enum HUDPresentation {
    static func shouldPresent(
        state: HUDLampState,
        hasFeedback: Bool,
        isOnboarding: Bool,
        prewarmPresentsHUD: Bool
    ) -> Bool {
        // setup owns the screen while it is open. a message that would
        // have spoken over it is held, not lost (HUDFeedbackGate).
        guard !isOnboarding else {
            return false
        }
        // exceptional messages always speak, warm-up or not.
        if hasFeedback {
            return true
        }

        switch state {
        case .idle:
            return false
        case .prewarming:
            // the ember means "not ready for the key you just pressed", so
            // at login it means nothing: nobody pressed anything. the menu
            // carries "loading the speech model…" for whoever looks, which
            // is where unprompted status belongs (ADR 0030).
            return prewarmPresentsHUD
        case .recording, .transcribing:
            return true
        }
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
