import Foundation

/// what to do with an exceptional message right now.
enum HUDFeedbackDecision: Equatable, Sendable {
    /// the screen is free: flash the pill and time it out as usual
    case flashNow
    /// the setup window has the screen and the panel is force-dismissed, so
    /// a timed pill would be spent against something nobody can see. keep it
    case hold
    /// held so long that arriving would read as a non-sequitur
    case drop
}

/// the policy, in one pure function, so it can be argued with in tests
/// instead of by revoking a permission mid-dictation by hand. the rule the
/// spec asks for: a failed dictation must never look like a successful one,
/// which it does when the one sentence the app owed you is swallowed by the
/// window that happened to open over it.
enum HUDFeedbackGate {
    /// long enough to finish a permission prompt, short enough that the
    /// pill still reads as being about the dictation you just did.
    static let holdLimit: TimeInterval = 30

    /// `heldFor` is nil for a message that has only just been built.
    static func decide(
        isOnboardingPresented: Bool,
        heldFor: TimeInterval?
    ) -> HUDFeedbackDecision {
        guard !isOnboardingPresented else {
            return .hold
        }
        guard let heldFor else {
            return .flashNow
        }
        return heldFor <= holdLimit ? .flashNow : .drop
    }
}
