import XCTest

/// a pill with a button must not leave from under the pointer that is on
/// its way to the button: its time stops while the pointer is over it.
final class PillCountdownTests: XCTestCase {
    func testItRunsDownFromWhenItWasShown() {
        let countdown = PillCountdown(lasts: .seconds(15), startedAt: .seconds(100))

        XCTAssertEqual(countdown.remaining(at: .seconds(100)), .seconds(15))
        XCTAssertEqual(countdown.remaining(at: .seconds(110)), .seconds(5))
        XCTAssertEqual(countdown.remaining(at: .seconds(120)), .zero)
    }

    func testItStopsWhileThePointerIsOverThePill() {
        var countdown = PillCountdown(lasts: .seconds(15), startedAt: .zero)

        countdown.pause(at: .seconds(4))
        XCTAssertEqual(countdown.remaining(at: .seconds(4)), .seconds(11))
        XCTAssertEqual(countdown.remaining(at: .seconds(60)), .seconds(11))

        countdown.resume(at: .seconds(60))
        XCTAssertEqual(countdown.remaining(at: .seconds(65)), .seconds(6))
    }

    /// the pointer can flicker in and out at the pill's edge: pausing a
    /// paused countdown, or resuming a running one, changes nothing.
    func testPausingTwiceOrResumingTwiceIsOneOfEach() {
        var countdown = PillCountdown(lasts: .seconds(15), startedAt: .zero)

        countdown.pause(at: .seconds(2))
        countdown.pause(at: .seconds(8))
        XCTAssertEqual(countdown.remaining(at: .seconds(9)), .seconds(13))

        countdown.resume(at: .seconds(10))
        countdown.resume(at: .seconds(12))
        XCTAssertEqual(countdown.remaining(at: .seconds(14)), .seconds(9))
        XCTAssertFalse(countdown.isPaused)
    }
}
