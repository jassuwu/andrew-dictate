/// the thirty seconds before the five-minute cap, counted in frames rather
/// than wall clock: a take that never got audio never warns, and one that
/// was sealed early never warns twice. the latch is the whole point — the
/// tap calls in on every buffer.
struct CaptureCapWarning: Sendable {
    /// the frame count that trips it, or 0 when there is nothing to warn
    /// about: a cap shorter than the lead is its own warning.
    let threshold: Int

    private var didWarn = false

    init(maximumFrameCount: Int, leadFrameCount: Int) {
        threshold = leadFrameCount > 0
            && maximumFrameCount > leadFrameCount
            ? maximumFrameCount - leadFrameCount
            : 0
    }

    var isArmed: Bool {
        threshold > 0 && !didWarn
    }

    mutating func shouldWarn(at frameCount: Int) -> Bool {
        guard isArmed, frameCount >= threshold else {
            return false
        }

        didWarn = true
        return true
    }

    mutating func reset() {
        didWarn = false
    }
}
