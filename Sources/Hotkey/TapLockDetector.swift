import Foundation

struct TapLockDetector {
    enum Action: Equatable {
        case begin(DictationMode)
        case end(DictationMode)
        case cancel(DictationMode)
        case lockBegin(DictationMode)
        case lockEnd(DictationMode)
        case lockCancel(DictationMode)
    }

    static let maximumTapDuration: TimeInterval = 0.300
    static let maximumTapGap: TimeInterval = 0.350

    private struct QuickTap {
        let mode: DictationMode
        let releasedAt: TimeInterval
    }

    private enum State {
        case idle
        case holding(
            mode: DictationMode,
            pressedAt: TimeInterval,
            isSecondTap: Bool
        )
        case cancelledHold(mode: DictationMode)
        case locked(mode: DictationMode)
        case endingLock(mode: DictationMode)
    }

    private var state: State = .idle
    private var previousQuickTap: QuickTap?

    mutating func modifierPressed(
        _ mode: DictationMode,
        at timestamp: TimeInterval
    ) -> [Action] {
        switch state {
        case .idle:
            let isSecondTap = isSecondTap(of: mode, at: timestamp)
            if !isSecondTap {
                previousQuickTap = nil
            }
            state = .holding(
                mode: mode,
                pressedAt: timestamp,
                isSecondTap: isSecondTap
            )
            return [.begin(mode)]

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
                previousQuickTap = nil
                state = .locked(mode: mode)
                return [.lockBegin(mode)]
            }

            previousQuickTap = isQuickTap
                ? QuickTap(mode: mode, releasedAt: timestamp)
                : nil
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
            previousQuickTap = nil
            state = .idle
            return [.lockEnd(mode)]

        case .idle, .locked:
            return []
        }
    }

    mutating func keyDown(isEscape: Bool) -> [Action] {
        switch state {
        case let .holding(mode, _, _):
            previousQuickTap = nil
            state = .cancelledHold(mode: mode)
            return [.cancel(mode)]

        case let .locked(mode), let .endingLock(mode):
            guard isEscape else {
                return []
            }
            previousQuickTap = nil
            state = .idle
            return [.lockCancel(mode)]

        case .idle:
            previousQuickTap = nil
            return []

        case .cancelledHold:
            return []
        }
    }

    mutating func cancelForRebind(_ mode: DictationMode) -> [Action] {
        switch state {
        case let .holding(heldMode, _, _) where heldMode == mode:
            previousQuickTap = nil
            state = .idle
            return [.cancel(mode)]

        case let .cancelledHold(heldMode) where heldMode == mode:
            state = .idle
            return []

        case let .locked(lockedMode) where lockedMode == mode,
             let .endingLock(lockedMode) where lockedMode == mode:
            previousQuickTap = nil
            state = .idle
            return [.lockCancel(mode)]

        default:
            if previousQuickTap?.mode == mode {
                previousQuickTap = nil
            }
            return []
        }
    }

    private func isSecondTap(
        of mode: DictationMode,
        at timestamp: TimeInterval
    ) -> Bool {
        guard let previousQuickTap,
              previousQuickTap.mode == mode else {
            return false
        }

        let gap = timestamp - previousQuickTap.releasedAt
        return gap >= 0 && gap < Self.maximumTapGap
    }
}
