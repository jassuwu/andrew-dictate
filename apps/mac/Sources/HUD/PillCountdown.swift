import Foundation

/// how long a pill with a button has left (ADR 0047). it runs from when the
/// pill went up and stops while the pointer is over it, so the pill never
/// leaves from under a hand on its way to the button. time is passed in.
struct PillCountdown: Equatable, Sendable {
    let lasts: Duration
    /// time already run, up to the last pause.
    private var spent: Duration = .zero
    /// running since then; nil while paused.
    private var runningSince: Duration?

    init(lasts: Duration, startedAt: Duration) {
        self.lasts = lasts
        runningSince = startedAt
    }

    var isPaused: Bool {
        runningSince == nil
    }

    mutating func pause(at now: Duration) {
        guard let runningSince else {
            return
        }
        spent += now - runningSince
        self.runningSince = nil
    }

    mutating func resume(at now: Duration) {
        guard runningSince == nil else {
            return
        }
        runningSince = now
    }

    func remaining(at now: Duration) -> Duration {
        let running = runningSince.map { now - $0 } ?? .zero
        return max(.zero, lasts - spent - running)
    }
}
