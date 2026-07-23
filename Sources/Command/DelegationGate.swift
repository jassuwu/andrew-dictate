import Foundation

struct DelegationGate {
    struct Pending: Equatable, Sendable {
        let prompt: String
        let commandPreview: String
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

    var isPending: Bool {
        if case .pending = state {
            return true
        }
        return false
    }

    var remainingTime: TimeInterval? {
        guard case let .pending(pending) = state else {
            return nil
        }
        return max(0, pending.expiresAt - now())
    }

    mutating func present(
        prompt: String,
        commandPreview: String
    ) {
        let presentedAt = now()
        state = .pending(
            Pending(
                prompt: prompt,
                commandPreview: commandPreview,
                expiresAt: presentedAt + timeout,
                commandKeyPressedAt: nil
            )
        )
    }

    mutating func commandKeyPressed() -> Outcome {
        guard case var .pending(pending) = state else {
            return .none
        }
        let pressedAt = now()
        guard pressedAt < pending.expiresAt else {
            state = .idle
            return .cancelled
        }

        pending.commandKeyPressedAt = pressedAt
        state = .pending(pending)
        return .none
    }

    mutating func commandKeyReleased() -> Outcome {
        guard case var .pending(pending) = state else {
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

    mutating func cancel() -> Outcome {
        guard isPending else {
            return .none
        }
        state = .idle
        return .cancelled
    }

    mutating func cancelIfTimedOut() -> Outcome {
        guard case let .pending(pending) = state,
              now() >= pending.expiresAt else {
            return .none
        }
        state = .idle
        return .cancelled
    }
}
