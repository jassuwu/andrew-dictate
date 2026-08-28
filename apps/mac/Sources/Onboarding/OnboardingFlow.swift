import Foundation

/// One screen of setup: one idea, one action.
///
/// The old onboarding was a single screen carrying four competing actions — a
/// setup button, a status checklist, a link into settings, and a skip — plus
/// three sentences of explanation before you had done anything. A person
/// arriving there had to work out which of the four was the next thing.
///
/// Each step here answers **why** the app is asking, not **what** the thing is
/// called. macOS shows you what a permission is the moment you click grant;
/// what it cannot tell you is why a dictation app wants it. "Accessibility" is
/// the one that needs this most — it sounds unrelated and faintly alarming
/// until you know it is how the text reaches your cursor.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case hello
    case microphone
    case accessibility
    case model
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hello: "andrew dictate"
        case .microphone: "the microphone"
        case .accessibility: "accessibility"
        case .model: "the speech model"
        case .ready: "ready"
        }
    }

    /// One sentence. Anything longer belongs on a different screen, or nowhere.
    var reason: String {
        switch self {
        case .hello:
            "hold fn, talk, let go. the text lands where your cursor is."
        case .microphone:
            "so it can hear you. nothing is sent anywhere."
        case .accessibility:
            "so the text can land in whatever app you're typing in."
        case .model:
            "one download, and then it works with no internet at all."
        case .ready:
            "hold fn, say something, let go."
        }
    }

    var actionTitle: String {
        switch self {
        case .hello: "set it up"
        case .microphone: "allow the microphone"
        case .accessibility: "allow accessibility"
        case .model: "download it"
        case .ready: "done"
        }
    }

    /// Only the first screen offers a way out. Past that the user has agreed to
    /// set up, and a second escape route on every screen is one of the four
    /// competing actions this redesign exists to remove.
    var offersSkip: Bool {
        self == .hello
    }
}

/// Where the user is, and whether they may move.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var step: OnboardingStep = .hello

    /// Back is always available once you have started, whether or not the
    /// current step is satisfied. Being able to retreat is what makes a
    /// stepped flow feel safe rather than like a trap.
    var canGoBack: Bool {
        step != .hello
    }

    var isLastStep: Bool {
        step == .ready
    }

    /// "3 of 5" — a bounded flow is a shorter-feeling flow.
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

    mutating func jump(to step: OnboardingStep) {
        self.step = step
    }

    /// Whether the current step's requirement is met, so the screen can move on
    /// by itself instead of making the user press a second button to confirm
    /// something they can already see happened.
    func isSatisfied(by state: OnboardingState) -> Bool {
        switch step {
        case .hello, .ready:
            true
        case .microphone:
            state.microphoneStatus == .ready
        case .accessibility:
            state.accessibilityStatus == .ready
        case .model:
            state.modelStatus == .ready
        }
    }
}
