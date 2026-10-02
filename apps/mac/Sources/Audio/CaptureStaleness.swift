/// whether the capture can still be trusted, and when the hardware has been
/// quiet long enough to build the next one. a monitor, the lid, airpods or
/// a call taking them each arrive as a burst of changes over a few hundred
/// milliseconds, and an engine built in the middle of one can bind to a
/// device that is already going away. pure: instants in, decisions out, so
/// the debounce is tested without a clock.
struct CaptureStaleness: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    /// how long nothing may move after the last change before the stale
    /// capture is thrown away.
    static let quiet = Duration.milliseconds(500)

    /// something moved underneath since the capture was last trusted.
    private(set) var isStale = false
    private var lastChange: Instant?

    /// when the quiet will have lasted long enough, if anything is waiting
    /// on it.
    var settlesAt: Instant? {
        guard isStale else {
            return nil
        }
        return lastChange.map { $0 + Self.quiet }
    }

    /// something moved: the capture is stale now, and the quiet starts over.
    mutating func changed(at instant: Instant) {
        isStale = true
        lastChange = instant
    }

    /// true once, when the capture is stale and nothing has moved for long
    /// enough: throw it away now.
    mutating func settle(at now: Instant) -> Bool {
        guard let settlesAt, now >= settlesAt else {
            return false
        }
        isStale = false
        lastChange = nil
        return true
    }
}
