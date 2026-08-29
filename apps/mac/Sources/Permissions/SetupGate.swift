import Foundation

/// what the app is allowed to do *right now*. never a memory of what it was
/// allowed to do once: a grant can be withdrawn in system settings at any
/// moment, and the app only finds out by asking again.
struct PermissionSnapshot: Equatable, Sendable {
    let microphoneGranted: Bool
    let accessibilityGranted: Bool

    /// dictation needs both. the hotkey is a global event monitor
    /// (accessibility) and capture needs the microphone — either one missing
    /// makes every keypress a silent no-op.
    var isDictationReady: Bool {
        microphoneGranted && accessibilityGranted
    }
}

/// when the app noticed. the same broken state earns a different answer
/// depending on whether the user just came to the app or is mid-sentence
/// somewhere else.
enum SetupCheckMoment: Equatable, Sendable {
    /// launch, or a reopen of the already-running app — focus is ours to take
    case launchOrReopen
    /// woke, unlocked, or a grant changed under us while we sat in the menu bar
    case midSession
}

enum SetupPresentation: Equatable, Sendable {
    /// show onboarding, taking focus
    case present
    /// something is missing, but interrupting whatever they're typing to say
    /// so would commit the one sin this app exists to prevent
    case badgeOnly
    case none
}

/// the whole policy, in one pure function, so it can be argued with in tests
/// instead of by launching the app and revoking things by hand.
enum SetupGate {
    static func presentation(
        onboardingDismissed: Bool,
        permissions: PermissionSnapshot,
        moment: SetupCheckMoment,
        dictationWanted: Bool = true
    ) -> SetupPresentation {
        guard onboardingDismissed else {
            return .present
        }
        // a meetings-only setup has nothing here to be re-verified: system
        // audio is proved at every capture (ADR 0021), and there is no
        // hotkey to be dead. nagging for accessibility would be asking for a
        // grant the app was told not to want.
        guard dictationWanted else {
            return .none
        }
        guard !permissions.isDictationReady else {
            return .none
        }
        return moment == .launchOrReopen ? .present : .badgeOnly
    }
}
