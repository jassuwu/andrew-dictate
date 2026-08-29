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
///
/// The screens are fixed; what they *say* is not. Setup forks by job (ADR
/// 0040), so every line of copy is a function of the ticks on the first card:
/// one model or two, two permissions or three, and a button that prices what
/// the click is about to download.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case hello
    case model
    case permissions

    var id: Int { rawValue }

    func title(for jobs: OnboardingJobs) -> String {
        switch self {
        case .hello:
            // Reopened from `record a meeting`, this window is not an
            // introduction to the app — you already have it. It is one errand.
            jobs.scope == .meetingsOnly
                ? "set up meeting recording"
                : "andrew dictate"
        case .model:
            jobs.dictation && jobs.meetings
                ? "the speech models"
                : "the speech model"
        case .permissions:
            Self.spelled(jobs.permissions.count)
        }
    }

    func reason(for jobs: OnboardingJobs) -> String {
        switch self {
        case .hello:
            jobs.scope == .meetingsOnly
                ? "your mic is you, their app is them. one english transcript."
                : "hold fn, talk, let go. the text lands where your cursor is."
        case .model:
            jobs.dictation && jobs.meetings
                ? "they run on this mac, so nothing you say needs the internet."
                : "it runs on this mac, so nothing you say needs the internet."
        case .permissions:
            switch (jobs.dictation, jobs.meetings) {
            case (true, true):
                "so it can hear you, type for you, and hear the meeting."
            case (true, false):
                "so it can hear you, and put the text where your cursor is."
            case (false, true):
                "so it can hear you, and hear the app you're meeting in."
            case (false, false):
                "so it can hear you."
            }
        }
    }

    /// The button says what the click costs, because the click is the moment
    /// the downloads start and nothing downloads before it (SPEC §5).
    func actionTitle(for jobs: OnboardingJobs) -> String {
        switch self {
        case .hello:
            let name = jobs.scope == .meetingsOnly
                ? "set up meeting recording"
                : "set up andrew dictate"
            let size = jobs.downloadSize
            return size.isEmpty ? name : "\(name) (\(size))"
        case .model:
            return "continue"
        case .permissions:
            return "done"
        }
    }

    private static func spelled(_ count: Int) -> String {
        switch count {
        case 1: "one permission"
        case 2: "two permissions"
        default: "three permissions"
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
