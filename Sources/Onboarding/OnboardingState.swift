import Foundation

enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case permissions
    case model
    case keysAndAgent
}

struct OnboardingFlowState: Equatable, Sendable {
    private(set) var step: OnboardingStep = .welcome
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false
    private(set) var permissionsSkipped = false
    private(set) var engineReady = false

    var canContinue: Bool {
        switch step {
        case .welcome, .keysAndAgent:
            true
        case .permissions:
            permissionsSkipped
                || (microphoneGranted && accessibilityGranted)
        case .model:
            engineReady
        }
    }

    mutating func updatePermissions(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
    }

    mutating func skipPermissions() {
        permissionsSkipped = true
    }

    mutating func updateEngineReady(_ isReady: Bool) {
        engineReady = isReady
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard canContinue,
              let nextStep = OnboardingStep(rawValue: step.rawValue + 1) else {
            return false
        }
        step = nextStep
        return true
    }

    mutating func goBack() {
        guard let previousStep = OnboardingStep(
            rawValue: step.rawValue - 1
        ) else {
            return
        }
        step = previousStep
    }
}
