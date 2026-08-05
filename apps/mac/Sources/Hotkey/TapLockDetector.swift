import Foundation

struct TapLockDetector {
    enum Action: Equatable {
        case begin
        case provisionalEnd
        case end
        case cancel
        case lockBegin
        case lockEnd
        case lockCancel
    }

    static let maximumTapDuration: TimeInterval = 0.300
    static let maximumTapGap: TimeInterval = 0.350

    private enum State {
        case idle
        case holding(
            pressedAt: TimeInterval,
            isSecondTap: Bool
        )
        case awaitingSecondTap(releasedAt: TimeInterval)
        case cancelledHold
        case locked
        case endingLock
    }

    private var state: State = .idle

    mutating func modifierPressed(at timestamp: TimeInterval) -> [Action] {
        switch state {
        case .idle:
            state = .holding(
                pressedAt: timestamp,
                isSecondTap: false
            )
            return [.begin]

        case let .awaitingSecondTap(releasedAt):
            let gap = timestamp - releasedAt
            if gap >= 0,
               gap < Self.maximumTapGap {
                state = .holding(
                    pressedAt: timestamp,
                    isSecondTap: true
                )
                return []
            }

            state = .holding(
                pressedAt: timestamp,
                isSecondTap: false
            )
            return [.end, .begin]

        case .locked:
            state = .endingLock
            return []

        case .holding, .cancelledHold, .endingLock:
            return []
        }
    }

    mutating func modifierReleased(at timestamp: TimeInterval) -> [Action] {
        switch state {
        case let .holding(pressedAt, isSecondTap):
            let duration = timestamp - pressedAt
            let isQuickTap = duration >= 0
                && duration < Self.maximumTapDuration

            if isSecondTap && isQuickTap {
                state = .locked
                return [.cancel, .lockBegin]
            }

            if isQuickTap {
                state = .awaitingSecondTap(
                    releasedAt: timestamp
                )
                // Only sub-300 ms taps wait for the 350 ms double-tap
                // window; real utterances are held longer and end immediately.
                return [.provisionalEnd]
            }

            state = .idle
            return [.end]

        case .cancelledHold:
            state = .idle
            return []

        case .endingLock:
            state = .idle
            return [.lockEnd]

        case .idle, .awaitingSecondTap, .locked:
            return []
        }
    }

    mutating func provisionalEndWindowExpired() -> [Action] {
        guard case .awaitingSecondTap = state else {
            return []
        }
        state = .idle
        return [.end]
    }

    mutating func keyDown(isEscape: Bool) -> [Action] {
        switch state {
        case .holding:
            state = .cancelledHold
            return [.cancel]

        case .locked, .endingLock:
            guard isEscape else {
                return []
            }
            state = .idle
            return [.lockCancel]

        case .idle, .awaitingSecondTap:
            return []

        case .cancelledHold:
            return []
        }
    }

    mutating func cancelForRebind() -> [Action] {
        switch state {
        case .holding:
            state = .idle
            return [.cancel]

        case .awaitingSecondTap:
            state = .idle
            return [.cancel]

        case .cancelledHold:
            state = .idle
            return []

        case .locked, .endingLock:
            state = .idle
            return [.lockCancel]

        case .idle:
            return []
        }
    }

    mutating func reset() -> [Action] {
        defer { state = .idle }

        switch state {
        case .holding, .awaitingSecondTap:
            return [.cancel]
        case .locked, .endingLock:
            return [.lockCancel]
        case .idle, .cancelledHold:
            return []
        }
    }
}
