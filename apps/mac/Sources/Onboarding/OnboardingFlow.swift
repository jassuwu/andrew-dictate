import Foundation

/// One screen of setup.
///
/// The first attempt at this split the three requirements onto three separate
/// screens, which turned "one idea per screen" into "one *permission* per
/// screen" — more steps, not fewer, and a download that blocked the flow while
/// it ran. This is the correction: the model downloads in the background from
/// the moment you say go, and the two permissions share one screen because they
/// are one idea — *what the app needs in order to work.*
///
/// Each screen answers **why**, not **what**. macOS shows you what a permission
/// is the instant you click grant; what it cannot tell you is why a dictation
/// app wants it. "Accessibility" needs this most — the name sounds unrelated
/// and faintly alarming until you know it is how text reaches your cursor.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case hello
    case model
    case permissions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hello: "andrew dictate"
        case .model: "the speech model"
        case .permissions: "two permissions"
        }
    }

    var reason: String {
        switch self {
        case .hello:
            "hold fn, talk, let go. the text lands where your cursor is."
        case .model:
            "it runs on this mac, so nothing you say needs the internet."
        case .permissions:
            "so it can hear you, and put the text where your cursor is."
        }
    }

    var actionTitle: String {
        switch self {
        case .hello: "get started"
        case .model: "continue"
        case .permissions: "done"
        }
    }
}

/// Where the user is. Movement is entirely theirs: nothing advances on its own.
///
/// The first attempt auto-advanced when a permission landed, which saved a
/// click and cost the thing that mattered — you could not tell whether the
/// grant had worked, because the screen that would have told you was already
/// gone.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var step: OnboardingStep = .hello

    var canGoBack: Bool {
        step != .hello
    }

    var canGoForward: Bool {
        step != OnboardingStep.allCases.last
    }

    var position: (index: Int, total: Int) {
        (step.rawValue + 1, OnboardingStep.allCases.count)
    }

    mutating func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            return
        }
        step = next
    }

    mutating func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else {
            return
        }
        step = previous
    }

    /// Any screen, any time. The dots are the control, not just an indicator —
    /// going back to check something should never mean walking the whole flow.
    mutating func jump(to step: OnboardingStep) {
        self.step = step
    }
}
