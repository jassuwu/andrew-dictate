import Foundation

struct TapLockDetector {
    enum Action: Equatable {
        case begin(DictationMode)
        case provisionalEnd(DictationMode)
        case end(DictationMode)
        case cancel(DictationMode)
        case lockBegin(DictationMode)
        case lockEnd(DictationMode)
        case lockCancel(DictationMode)
    }

    static let maximumTapDuration: TimeInterval = 0.300
    static let maximumTapGap: TimeInterval = 0.350

    private enum State {
        case idle
        case holding(
            mode: DictationMode,
            pressedAt: TimeInterval,
            isSecondTap: Bool
        )
        case awaitingSecondTap(
            mode: DictationMode,
            releasedAt: TimeInterval
        )
        case cancelledHold(mode: DictationMode)
        case locked(mode: DictationMode)
        case endingLock(mode: DictationMode)
    }

    private var state: State = .idle

    mutating func modifierPressed(
        _ mode: DictationMode,
        at timestamp: TimeInterval
    ) -> [Action] {
        switch state {
        case .idle:
            state = .holding(
                mode: mode,
                pressedAt: timestamp,
                isSecondTap: false
            )
            return [.begin(mode)]

        case let .awaitingSecondTap(pendingMode, releasedAt):
            let gap = timestamp - releasedAt
            if mode == pendingMode,
               gap >= 0,
               gap < Self.maximumTapGap {
                state = .holding(
                    mode: mode,
                    pressedAt: timestamp,
                    isSecondTap: true
                )
                return []
            }

            state = .holding(
                mode: mode,
                pressedAt: timestamp,
                isSecondTap: false
            )
            return [.end(pendingMode), .begin(mode)]

        case let .locked(lockedMode):
            guard mode == lockedMode else {
                return []
            }
            state = .endingLock(mode: mode)
            return []

        case .holding, .cancelledHold, .endingLock:
            return []
        }
    }

    mutating func modifierReleased(
        _ mode: DictationMode,
        at timestamp: TimeInterval
    ) -> [Action] {
        switch state {
        case let .holding(heldMode, pressedAt, isSecondTap):
            guard mode == heldMode else {
                return []
            }

            let duration = timestamp - pressedAt
            let isQuickTap = duration >= 0
                && duration < Self.maximumTapDuration

            if isSecondTap && isQuickTap {
                state = .locked(mode: mode)
                return [.cancel(mode), .lockBegin(mode)]
            }

            if isQuickTap {
                state = .awaitingSecondTap(
                    mode: mode,
                    releasedAt: timestamp
                )
                // Only sub-300 ms taps wait for the 350 ms double-tap
                // window; real utterances are held longer and end immediately.
                return [.provisionalEnd(mode)]
            }

            state = .idle
            return [.end(mode)]

        case let .cancelledHold(heldMode):
            guard mode == heldMode else {
                return []
            }
            state = .idle
            return []

        case let .endingLock(lockedMode):
            guard mode == lockedMode else {
                return []
            }
            state = .idle
            return [.lockEnd(mode)]

        case .idle, .awaitingSecondTap, .locked:
            return []
        }
    }

    mutating func provisionalEndWindowExpired() -> [Action] {
        guard case let .awaitingSecondTap(mode, _) = state else {
            return []
        }
        state = .idle
        return [.end(mode)]
    }

    mutating func keyDown(isEscape: Bool) -> [Action] {
        switch state {
        case let .holding(mode, _, _):
            state = .cancelledHold(mode: mode)
            return [.cancel(mode)]

        case let .locked(mode), let .endingLock(mode):
            guard isEscape else {
                return []
            }
            state = .idle
            return [.lockCancel(mode)]

        case .idle, .awaitingSecondTap:
            return []

        case .cancelledHold:
            return []
        }
    }

    mutating func cancelForRebind(_ mode: DictationMode) -> [Action] {
        switch state {
        case let .holding(heldMode, _, _) where heldMode == mode:
            state = .idle
            return [.cancel(mode)]

        case let .awaitingSecondTap(pendingMode, _)
            where pendingMode == mode:
            state = .idle
            return [.cancel(mode)]

        case let .cancelledHold(heldMode) where heldMode == mode:
            state = .idle
            return []

        case let .locked(lockedMode) where lockedMode == mode,
             let .endingLock(lockedMode) where lockedMode == mode:
            state = .idle
            return [.lockCancel(mode)]

        default:
            return []
        }
    }
}
