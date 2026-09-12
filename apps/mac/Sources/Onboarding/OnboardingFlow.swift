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

    /// `verdict` only reaches the last screen: it is what that card is
    /// allowed to claim, and the first two claim nothing.
    func title(
        for jobs: OnboardingJobs,
        verdict: OnboardingVerdict = .incomplete
    ) -> String {
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
            if verdict == .ready {
                "ready"
            } else if jobs.scope == .permissionsOnly {
                // not an introduction and not a count: one switch went off.
                "say yes again"
            } else {
                Self.spelled(jobs.permissions.count)
            }
        }
    }

    /// `key` is the binding as it stands, not the shipped default: someone who
    /// rebound to right ⌥ must not be told to hold fn.
    func reason(
        for jobs: OnboardingJobs,
        key: String,
        verdict: OnboardingVerdict = .incomplete
    ) -> String {
        switch self {
        case .hello:
            return jobs.scope == .meetingsOnly
                ? "your mic is you, their app is them. one english transcript."
                : "hold \(key), talk, let go. the text lands where your cursor is."
        case .model:
            return jobs.dictation && jobs.meetings
                ? "they run on this mac, so nothing you say needs the internet."
                : "it runs on this mac, so nothing you say needs the internet."
        case .permissions:
            switch verdict {
            case .ready:
                return jobs.dictation
                    ? "that's everything macos had to say yes to."
                    : "that's everything. your mic is you, their app is them."
            case .downloading:
                // closing is allowed to be the right answer here, so say so.
                return "granted. the model is still coming down — closing won't stop it."
            case .incomplete:
                if jobs.scope == .permissionsOnly {
                    return "already set up — macos dropped a permission. nothing to download."
                }
                switch (jobs.dictation, jobs.meetings) {
                case (true, true):
                    return "so it can hear you, type for you, and hear the meeting."
                case (true, false):
                    return "so it can hear you, and put the text where your cursor is."
                case (false, true):
                    return "so it can hear you, and hear the app you're meeting in."
                case (false, false):
                    return "so it can hear you."
                }
            }
        }
    }

    /// The button says what the click costs, because the click is the moment
    /// the downloads start and nothing downloads before it (SPEC §5). On the
    /// last card it says what the click *is*: only "done" claims setup
    /// finished, so a card with a permission missing offers "close" instead.
    func actionTitle(
        for jobs: OnboardingJobs,
        verdict: OnboardingVerdict = .incomplete
    ) -> String {
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
            switch verdict {
            case .ready:
                // the errand this window was opened for, named — as long as
                // it fits the button the flow tests keep short.
                if let app = jobs.meetingApp, app.count <= 17 {
                    return "record \(app)"
                }
                return jobs.dictation ? "start dictating" : "done"
            case .downloading:
                return "done"
            case .incomplete:
                return "close"
            }
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
    private(set) var step: OnboardingStep

    /// Setup can open on the screen that is actually broken: a returning user
    /// who lost a grant has no jobs to pick and nothing to download.
    init(step: OnboardingStep = .hello) {
        self.step = step
    }

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
