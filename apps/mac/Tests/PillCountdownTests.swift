import XCTest

/// a pill with a button must not leave from under the pointer that is on
/// its way to the button: its time stops once the pointer moves onto it.
/// a pointer that was resting where the pill came up has not reached for
/// it, and stops nothing; and no hand holds it up for more than a minute.
final class PillCountdownTests: XCTestCase {
    private let resting = CGPoint(x: 700, y: 120)
    private let onThePill = CGPoint(x: 720, y: 124)
    private let elsewhere = CGPoint(x: 300, y: 600)

    private func countdown(lasts: Duration = .seconds(15), at start: Duration = .zero) -> PillCountdown {
        PillCountdown(lasts: lasts, startedAt: start, pointerAt: resting)
    }

    func testItRunsDownFromWhenItWasShown() {
        let countdown = countdown(at: .seconds(100))

        XCTAssertEqual(countdown.remaining(at: .seconds(100)), .seconds(15))
        XCTAssertEqual(countdown.remaining(at: .seconds(110)), .seconds(5))
        XCTAssertEqual(countdown.remaining(at: .seconds(120)), .zero)
        XCTAssertEqual(countdown.timeLeft(at: .seconds(110)), .seconds(5))
    }

    func testItStopsWhileThePointerIsOverThePill() {
        var countdown = countdown()

        countdown.pointer(isOver: true, at: onThePill, now: .seconds(4))
        XCTAssertTrue(countdown.isHeld)
        XCTAssertEqual(countdown.remaining(at: .seconds(4)), .seconds(11))
        XCTAssertEqual(countdown.remaining(at: .seconds(50)), .seconds(11))

        countdown.pointer(isOver: false, at: elsewhere, now: .seconds(50))
        XCTAssertFalse(countdown.isHeld)
        XCTAssertEqual(countdown.remaining(at: .seconds(55)), .seconds(6))
    }

    /// the pointer can flicker in and out at the pill's edge: over twice,
    /// or off twice, is one of each.
    func testOverTwiceOrOffTwiceIsOneOfEach() {
        var countdown = countdown()

        countdown.pointer(isOver: true, at: onThePill, now: .seconds(2))
        countdown.pointer(isOver: true, at: onThePill, now: .seconds(8))
        XCTAssertEqual(countdown.remaining(at: .seconds(9)), .seconds(13))

        countdown.pointer(isOver: false, at: elsewhere, now: .seconds(10))
        countdown.pointer(isOver: false, at: elsewhere, now: .seconds(12))
        XCTAssertEqual(countdown.remaining(at: .seconds(14)), .seconds(9))
        XCTAssertFalse(countdown.isHeld)
    }

    /// the mouse parked at the bottom of the screen, over a call's toolbar,
    /// and the pill comes up under it: nobody reached for it, so it runs
    /// down as if the pointer were anywhere else.
    func testAPointerRestingWhereThePillCameUpDoesNotStopIt() {
        var countdown = countdown()

        countdown.pointer(isOver: true, at: resting, now: .milliseconds(30))

        XCTAssertFalse(countdown.isHeld)
        XCTAssertEqual(countdown.remaining(at: .seconds(10)), .seconds(5))
        XCTAssertEqual(countdown.timeLeft(at: .seconds(10)), .seconds(5))
    }

    /// once the resting pointer has moved — off the pill and back, or on
    /// from anywhere — it is a hand on its way to the button.
    func testAPointerThatMovesOffAndBackOnStopsIt() {
        var countdown = countdown()
        countdown.pointer(isOver: true, at: resting, now: .milliseconds(30))

        countdown.pointer(isOver: false, at: elsewhere, now: .seconds(3))
        countdown.pointer(isOver: true, at: resting, now: .seconds(5))

        XCTAssertTrue(countdown.isHeld)
        XCTAssertEqual(countdown.remaining(at: .seconds(20)), .seconds(10))
    }

    /// a hand left on the pill holds it up for a minute, no longer: then it
    /// runs out from under it, and the 30 a second pointer watch with it.
    func testAHandOnThePillHoldsItForAMinuteAtMost() {
        XCTAssertEqual(PillCountdown.longestHold, .seconds(60))
        var countdown = countdown()

        countdown.pointer(isOver: true, at: onThePill, now: .seconds(4))
        XCTAssertEqual(countdown.timeLeft(at: .seconds(4)), .seconds(71))
        XCTAssertEqual(countdown.remaining(at: .seconds(64)), .seconds(11))
        XCTAssertEqual(countdown.remaining(at: .seconds(70)), .seconds(5))
        XCTAssertEqual(countdown.timeLeft(at: .seconds(70)), .seconds(5))
        XCTAssertEqual(countdown.remaining(at: .seconds(75)), .zero)
    }

    /// the minute is all told, not each time: in and out does not buy a
    /// fresh one.
    func testTheMinuteIsAllToldNotEachTime() {
        var countdown = countdown()

        countdown.pointer(isOver: true, at: onThePill, now: .seconds(0))
        countdown.pointer(isOver: false, at: elsewhere, now: .seconds(40))
        countdown.pointer(isOver: true, at: onThePill, now: .seconds(41))

        // held 40 of the 60; one second ran between.
        XCTAssertEqual(countdown.timeLeft(at: .seconds(41)), .seconds(34))
        XCTAssertEqual(countdown.remaining(at: .seconds(61)), .seconds(14))
        XCTAssertEqual(countdown.remaining(at: .seconds(70)), .seconds(5))
    }
}
