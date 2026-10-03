import XCTest

/// The chunks' clock as the source keeps it: frames out, and the time
/// nothing came skipped and told. Each buffer says where on the wall it
/// began; one that begins more than a fifth of a second after the last
/// one ended is past an outage. Instants and frame counts in, stamps and
/// outages out.
final class ChunkClockTests: XCTestCase {
    private let origin = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        origin + .seconds(seconds)
    }

    /// Ten-millisecond buffers one after another, a tenth of a second of
    /// chunks out of them: nothing skipped, and the stamps are the frames.
    func testBuffersThatRunOnAreStampedByTheirFrames() {
        var clock = ChunkClock()
        for i in 0..<20 {
            XCTAssertNil(clock.buffer(began: at(Double(i) * 0.01), lasting: .milliseconds(10)))
        }
        XCTAssertEqual(clock.stamp, .zero)
        clock.delivered(1_600)
        XCTAssertEqual(clock.stamp, .milliseconds(100))
        clock.delivered(1_600)
        XCTAssertEqual(clock.stamp, .milliseconds(200))
    }

    /// A buffer late by a tenth of a second is the hardware's jitter: left
    /// alone, nothing told.
    func testABufferLateByLessThanTheOutageIsLeftAlone() {
        var clock = ChunkClock()
        XCTAssertNil(clock.buffer(began: at(0), lasting: .milliseconds(10)))
        clock.delivered(1_600)
        XCTAssertNil(clock.buffer(began: at(0.21), lasting: .milliseconds(10)))
        XCTAssertEqual(clock.stamp, .milliseconds(100))
    }

    /// The airpods died after a second, and the built-in mic's rig took
    /// over four seconds after the last buffer: an outage from where the
    /// chunks had got to, four seconds long, and the next chunk after it.
    func testAMicThatWentBeforeTheNextTookOverIsAnOutage() {
        var clock = ChunkClock()
        XCTAssertNil(clock.buffer(began: at(0), lasting: .seconds(1)))
        clock.delivered(16_000)

        clock.newRig()
        let outage = clock.buffer(began: at(5), lasting: .milliseconds(10))

        XCTAssertEqual(outage, .init(from: .seconds(1), to: .seconds(5)))
        XCTAssertEqual(clock.stamp, .seconds(5))
    }

    /// The lid shut half a minute in and opened twenty minutes later, and
    /// the same rig called back: the wall jumped between two of its
    /// buffers, and that is a twenty-minute outage.
    func testTheWallJumpingBetweenTwoBuffersIsAnOutageAsLongAsTheJump() {
        var clock = ChunkClock()
        XCTAssertNil(clock.buffer(began: at(0), lasting: .seconds(30)))
        clock.delivered(480_000)

        let outage = clock.buffer(began: at(1_230), lasting: .milliseconds(10))

        XCTAssertEqual(outage, .init(from: .seconds(30), to: .seconds(1_230)))
        XCTAssertEqual(clock.stamp, .seconds(1_230))
    }

    /// Two rigs on the same mic hear the same moment: the new one's first
    /// buffer can begin before the old one's last ended. Nothing came late,
    /// and nothing is skipped.
    func testANewRigThatOverlapsTheOldIsNoOutage() {
        var clock = ChunkClock()
        XCTAssertNil(clock.buffer(began: at(0), lasting: .seconds(1)))
        clock.newRig()
        XCTAssertNil(clock.buffer(began: at(0.95), lasting: .milliseconds(10)))
        XCTAssertNil(clock.buffer(began: at(0.96), lasting: .milliseconds(10)))
    }

    /// Where a moment of the wall is on the chunks' clock, for a tone of
    /// ours played then: the chunks out, what the live rig still holds
    /// towards the next, and — past an outage — the time since its last
    /// buffer, which the next buffer will skip.
    func testWhereTheWallIsOnTheChunksClock() {
        var clock = ChunkClock()
        XCTAssertEqual(ms(clock.position(at: at(0))), 0, "nothing yet")
        XCTAssertNil(clock.buffer(began: at(0), lasting: .milliseconds(150)))
        clock.delivered(1_600)
        XCTAssertEqual(ms(clock.position(at: at(0.155))), 150, "a chunk out, half one held")

        clock.newRig()
        XCTAssertEqual(ms(clock.position(at: at(0.155))), 100, "the old rig's half is gone with it")
        XCTAssertEqual(ms(clock.position(at: at(10.15))), 10_100, "ten seconds of nothing")
    }

    private func ms(_ duration: Duration) -> Int {
        Int((duration.totalSeconds * 1_000).rounded())
    }

    /// The buffer's own end decides whether a rig is delivering: its last
    /// buffer ended within the time asked about.
    func testARigIsDeliveringWhileItsBuffersAreRecent() {
        var clock = ChunkClock()
        XCTAssertFalse(clock.delivering(at: at(0), within: .seconds(1)), "none yet")
        XCTAssertNil(clock.buffer(began: at(0), lasting: .milliseconds(10)))
        XCTAssertTrue(clock.delivering(at: at(0.5), within: .seconds(1)))
        XCTAssertFalse(clock.delivering(at: at(2), within: .seconds(1)))
    }
}
