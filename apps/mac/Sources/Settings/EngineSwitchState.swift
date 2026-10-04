import Foundation

enum EngineSwitchPreparationOutcome: Equatable, Sendable {
    case ready
    case failed
}

enum EngineSwitchResolution: Equatable, Sendable {
    case ignored
    case swapped(from: SpeechModel, to: SpeechModel)
    case reverted(to: SpeechModel, message: String)
}

struct EngineSwitchState: Equatable, Sendable {
    private(set) var activeVersion: SpeechModel
    private(set) var targetVersion: SpeechModel?
    private(set) var failureMessage: String?

    init(activeVersion: SpeechModel) {
        self.activeVersion = activeVersion
    }

    @discardableResult
    mutating func beginPreparing(
        _ version: SpeechModel
    ) -> Bool {
        failureMessage = nil
        guard version != activeVersion else {
            targetVersion = nil
            return false
        }

        targetVersion = version
        return true
    }

    @discardableResult
    mutating func cancelPreparation() -> SpeechModel {
        targetVersion = nil
        failureMessage = nil
        return activeVersion
    }

    mutating func resolvePreparation(
        for version: SpeechModel,
        outcome: EngineSwitchPreparationOutcome
    ) -> EngineSwitchResolution {
        guard targetVersion == version else {
            return .ignored
        }

        targetVersion = nil
        switch outcome {
        case .ready:
            let previousVersion = activeVersion
            activeVersion = version
            failureMessage = nil
            return .swapped(
                from: previousVersion,
                to: version
            )

        case .failed:
            let message =
                "couldn't switch — still on "
                + activeVersion.shortName
            failureMessage = message
            return .reverted(
                to: activeVersion,
                message: message
            )
        }
    }
}
