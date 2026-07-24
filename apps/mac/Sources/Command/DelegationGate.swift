import Foundation

struct DelegationGate {
    struct Pending: Equatable, Sendable {
        let prompt: String
        let commandPreview: String
        let generation: UInt64
        let armedAt: TimeInterval
        let expiresAt: TimeInterval
        fileprivate var commandKeyPressedAt: TimeInterval?
    }

    enum State: Equatable, Sendable {
        case idle
        case pending(Pending)
    }

    enum Outcome: Equatable, Sendable {
        case none
        case confirmed(prompt: String)
        case cancelled
    }

    static let defaultTimeout: TimeInterval = 8
    static let maximumConfirmationTapDuration: TimeInterval = 0.300
    static let minimumArmingDelay: TimeInterval = 0.250

    private(set) var state: State = .idle

    private let timeout: TimeInterval
    private let now: () -> TimeInterval

    init(
        timeout: TimeInterval = Self.defaultTimeout,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.timeout = timeout
        self.now = now
    }

    func isPending(generation: UInt64) -> Bool {
        guard case let .pending(pending) = state else {
            return false
        }
        return pending.generation == generation
    }

    func remainingTime(generation: UInt64) -> TimeInterval? {
        guard case let .pending(pending) = state,
              pending.generation == generation else {
            return nil
        }
        return max(0, pending.expiresAt - now())
    }

    mutating func present(
        prompt: String,
        commandPreview: String,
        generation: UInt64
    ) {
        let presentedAt = now()
        state = .pending(
            Pending(
                prompt: prompt,
                commandPreview: commandPreview,
                generation: generation,
                armedAt: presentedAt + Self.minimumArmingDelay,
                expiresAt: presentedAt + timeout,
                commandKeyPressedAt: nil
            )
        )
    }

    mutating func commandKeyPressed(
        generation: UInt64
    ) -> Outcome {
        guard case var .pending(pending) = state,
              pending.generation == generation else {
            return .none
        }
        let pressedAt = now()
        guard pressedAt < pending.expiresAt else {
            state = .idle
            return .cancelled
        }
        guard pressedAt >= pending.armedAt else {
            return .none
        }

        pending.commandKeyPressedAt = pressedAt
        state = .pending(pending)
        return .none
    }

    mutating func commandKeyReleased(
        generation: UInt64
    ) -> Outcome {
        guard case var .pending(pending) = state,
              pending.generation == generation else {
            return .none
        }

        let releasedAt = now()
        guard releasedAt < pending.expiresAt else {
            state = .idle
            return .cancelled
        }
        guard let pressedAt = pending.commandKeyPressedAt else {
            return .none
        }

        pending.commandKeyPressedAt = nil
        let duration = releasedAt - pressedAt
        guard duration >= 0,
              duration < Self.maximumConfirmationTapDuration else {
            state = .pending(pending)
            return .none
        }

        state = .idle
        return .confirmed(prompt: pending.prompt)
    }

    mutating func cancel(generation: UInt64) -> Outcome {
        guard case let .pending(pending) = state,
              pending.generation == generation else {
            return .none
        }
        state = .idle
        return .cancelled
    }

    mutating func cancelForStateReplacement() -> Outcome {
        guard case .pending = state else {
            return .none
        }
        state = .idle
        return .cancelled
    }

    mutating func cancelIfTimedOut(
        generation: UInt64
    ) -> Outcome {
        guard case let .pending(pending) = state,
              pending.generation == generation,
              now() >= pending.expiresAt else {
            return .none
        }
        state = .idle
        return .cancelled
    }
}
