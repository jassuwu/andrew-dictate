import Foundation

/// how long a pill with a button has left (ADR 0047). it runs from when the
/// pill went up and stops once the pointer moves onto it, so the pill never
/// leaves from under a hand on its way to the button. a pointer that was
/// already resting where the pill came up — the mouse parked over a call's
/// toolbar — has not reached for it, and stops nothing. and no hand holds
/// it up for longer than `longestHold`, all told. time is passed in.
struct PillCountdown: Equatable, Sendable {
    /// how long a hand on the pill can hold it up, all told. a guess, like
    /// the questions' own times.
    static let longestHold: Duration = .seconds(60)

    let lasts: Duration
    private let startedAt: Duration
    /// time held, up to the last time a hold ended.
    private var held: Duration = .zero
    /// held since then; nil while it runs.
    private var heldSince: Duration?
    /// where the pointer was when the pill went up, until it is seen
    /// anywhere else.
    private var restingAt: CGPoint?

    init(lasts: Duration, startedAt: Duration, pointerAt: CGPoint) {
        self.lasts = lasts
        self.startedAt = startedAt
        restingAt = pointerAt
    }

    /// a hand moved onto the pill and is still there.
    var isHeld: Bool {
        heldSince != nil
    }

    /// the pointer is over the pill, or not, and where it is. over, it
    /// holds the pill up — unless it has not moved since the pill came up.
    mutating func pointer(isOver over: Bool, at point: CGPoint, now: Duration) {
        if point != restingAt {
            restingAt = nil
        }
        if over, restingAt == nil {
            hold(at: now)
        } else if !over {
            release(at: now)
        }
    }

    /// what is left of its own time, not counting a hold.
    func remaining(at now: Duration) -> Duration {
        let ran = now - startedAt - heldSoFar(at: now)
        return max(.zero, lasts - ran)
    }

    /// how long from now until it runs out, if the pointer stays where it
    /// is: what is left of a hold first, then what is left of its time.
    func timeLeft(at now: Duration) -> Duration {
        let left = remaining(at: now)
        guard heldSince != nil else {
            return left
        }
        return max(.zero, Self.longestHold - heldSoFar(at: now)) + left
    }

    private mutating func hold(at now: Duration) {
        guard heldSince == nil else {
            return
        }
        heldSince = now
    }

    private mutating func release(at now: Duration) {
        guard heldSince != nil else {
            return
        }
        held = heldSoFar(at: now)
        heldSince = nil
    }

    private func heldSoFar(at now: Duration) -> Duration {
        let holding = heldSince.map { now - $0 } ?? .zero
        return min(Self.longestHold, held + holding)
    }
}
