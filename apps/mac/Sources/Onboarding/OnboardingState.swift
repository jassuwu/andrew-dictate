import Foundation

enum OnboardingRowStatus: Equatable, Sendable {
    case pending
    case actionRequired
    case ready
}

enum OnboardingCompletion: Equatable, Sendable {
    case pending
    case finished
    case skipped
}

struct OnboardingState: Equatable, Sendable {
    private(set) var consented = false
    private(set) var microphoneStatus: OnboardingRowStatus = .pending
    private(set) var accessibilityStatus: OnboardingRowStatus = .pending
    private(set) var modelStatus: OnboardingRowStatus = .pending
    private(set) var whileYouWaitVisible = false
    private(set) var optionalConfigurationIsEditing = false
    private(set) var completion: OnboardingCompletion = .pending

    var autoFinishArmed: Bool {
        completion == .pending
            && microphoneStatus == .ready
            && accessibilityStatus == .ready
            && modelStatus == .ready
    }

    var autoFinishReady: Bool {
        autoFinishArmed && !optionalConfigurationIsEditing
    }

    @discardableResult
    mutating func consentToSetup() -> Bool {
        guard completion == .pending, !consented else {
            return false
        }

        consented = true
        whileYouWaitVisible = modelStatus != .ready
        if accessibilityStatus == .pending {
            accessibilityStatus = .actionRequired
        }
        return true
    }

    mutating func updateMicrophoneStatus(
        _ status: OnboardingRowStatus
    ) {
        microphoneStatus = status
    }

    mutating func updateAccessibility(granted: Bool) {
        accessibilityStatus = granted
            ? .ready
            : consented ? .actionRequired : .pending
    }

    mutating func updateModelStatus(
        _ status: OnboardingRowStatus
    ) {
        modelStatus = status
    }

    mutating func setOptionalConfigurationEditing(_ isEditing: Bool) {
        optionalConfigurationIsEditing =
            whileYouWaitVisible && isEditing
    }

    @discardableResult
    mutating func finishAutomatically() -> Bool {
        guard autoFinishReady else {
            return false
        }
        completion = .finished
        return true
    }

    @discardableResult
    mutating func skipForNow() -> Bool {
        guard completion == .pending else {
            return false
        }
        completion = .skipped
        return true
    }
}
