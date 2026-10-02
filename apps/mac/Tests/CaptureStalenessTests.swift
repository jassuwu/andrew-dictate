import XCTest

/// when the capture stops being trusted, and when the hardware has been
/// quiet long enough to build the next one. instants in, decisions out.
final class CaptureStalenessTests: XCTestCase {
    private let origin = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        origin + .milliseconds(milliseconds)
    }

    func testNothingMovedNothingIsStale() {
        var staleness = CaptureStaleness()

        XCTAssertFalse(staleness.isStale)
        XCTAssertNil(staleness.settlesAt)
        XCTAssertFalse(staleness.settle(at: at(10_000)))
    }

    /// a change makes the capture stale at once; it is thrown away only
    /// after half a second with nothing else moving.
    func testAChangeSettlesAfterHalfASecondOfQuiet() {
        var staleness = CaptureStaleness()

        staleness.changed(at: at(0))

        XCTAssertTrue(staleness.isStale)
        XCTAssertEqual(staleness.settlesAt, at(500))
        XCTAssertFalse(staleness.settle(at: at(499)))
        XCTAssertTrue(staleness.settle(at: at(500)))
        XCTAssertFalse(staleness.isStale)
        // settled once is settled: the next look finds nothing to do.
        XCTAssertFalse(staleness.settle(at: at(600)))
        XCTAssertNil(staleness.settlesAt)
    }

    /// a monitor or the lid is a burst of changes, not one. the quiet
    /// starts over with each, so the capture is rebuilt once, after the last.
    func testABurstSettlesHalfASecondAfterItsLastChange() {
        var staleness = CaptureStaleness()

        staleness.changed(at: at(0))
        staleness.changed(at: at(300))
        XCTAssertFalse(staleness.settle(at: at(500)))
        staleness.changed(at: at(600))

        XCTAssertEqual(staleness.settlesAt, at(1_100))
        XCTAssertFalse(staleness.settle(at: at(1_000)))
        XCTAssertTrue(staleness.isStale)
        XCTAssertTrue(staleness.settle(at: at(1_100)))
    }

    /// a look that comes late still settles: quiet for longer than needed
    /// is quiet.
    func testALateLookStillSettles() {
        var staleness = CaptureStaleness()

        staleness.changed(at: at(0))

        XCTAssertTrue(staleness.settle(at: at(5_000)))
    }
}
