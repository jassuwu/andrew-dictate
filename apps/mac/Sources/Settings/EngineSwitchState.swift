import Foundation

enum EngineSwitchPreparationOutcome: Equatable, Sendable {
    case ready
    case failed
}

enum EngineSwitchResolution: Equatable, Sendable {
    case ignored
    case swapped(from: EngineVersion, to: EngineVersion)
    case reverted(to: EngineVersion, message: String)
}

struct EngineSwitchState: Equatable, Sendable {
    private(set) var activeVersion: EngineVersion
    private(set) var targetVersion: EngineVersion?
    private(set) var failureMessage: String?

    init(activeVersion: EngineVersion) {
        self.activeVersion = activeVersion
    }

    @discardableResult
    mutating func beginPreparing(
        _ version: EngineVersion
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
    mutating func cancelPreparation() -> EngineVersion {
        targetVersion = nil
        failureMessage = nil
        return activeVersion
    }

    mutating func resolvePreparation(
        for version: EngineVersion,
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
                "couldn't switch — still on parakeet "
                + activeVersion.rawValue
            failureMessage = message
            return .reverted(
                to: activeVersion,
                message: message
            )
        }
    }
}
