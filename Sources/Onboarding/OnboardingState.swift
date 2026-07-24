import Foundation

enum OnboardingMissingItem: String, CaseIterable, Equatable, Sendable {
    case microphone
    case accessibility
    case model
}

enum OnboardingCompletion: Equatable, Sendable {
    case pending
    case finished
    case skipped
}

struct OnboardingState: Equatable, Sendable {
    private(set) var setupConsented = false
    private(set) var modelPreparationStarted = false
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false
    private(set) var engineReady = false
    private(set) var completion: OnboardingCompletion = .pending

    var sectionsEnabled: Bool {
        setupConsented || modelPreparationStarted
    }

    var finishEnabled: Bool {
        missingItems.isEmpty
    }

    var missingItems: [OnboardingMissingItem] {
        OnboardingMissingItem.allCases.filter { item in
            switch item {
            case .microphone:
                !microphoneGranted
            case .accessibility:
                !accessibilityGranted
            case .model:
                !engineReady
            }
        }
    }

    mutating func consentToSetup() {
        setupConsented = true
    }

    mutating func updatePermissions(
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
    }

    mutating func updateEngine(
        preparationStarted: Bool,
        ready: Bool
    ) {
        modelPreparationStarted = preparationStarted || ready
        engineReady = ready
    }

    @discardableResult
    mutating func finish() -> Bool {
        guard finishEnabled else {
            return false
        }
        completion = .finished
        return true
    }

    @discardableResult
    mutating func skipForNow() -> Bool {
        guard sectionsEnabled else {
            return false
        }
        completion = .skipped
        return true
    }
}
