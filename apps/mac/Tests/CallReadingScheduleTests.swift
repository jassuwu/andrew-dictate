import XCTest

/// When the call reader asks Core Audio who holds the mic, and when it stops
/// asking. Nobody on a call costs nothing.
final class CallReadingScheduleTests: XCTestCase {
    private func plan(
        _ schedule: inout CallReadingSchedule,
        at seconds: Double,
        mic: Bool = false,
        recording: Bool = false,
        call: Bool = false,
        others: Bool = true
    ) -> CallReadingSchedule.Plan {
        schedule.plan(
            at: .milliseconds(Int(seconds * 1_000)),
            micInUse: mic,
            isRecording: recording,
            followingACall: call,
            othersOnTheMic: others
        )
    }

    private func at(_ seconds: Double) -> Duration {
        .milliseconds(Int(seconds * 1_000))
    }

    /// The mic idle, nothing recording, no call: nothing to read and no
    /// reason to come back.
    func testNobodyOnTheMicReadsNothingAndStops() {
        var schedule = CallReadingSchedule()

        XCTAssertEqual(
            plan(&schedule, at: 0),
            CallReadingSchedule.Plan(step: nil, next: nil)
        )
    }

    /// Somebody took the mic: read now, then every two seconds while they
    /// hold it.
    func testTheMicInUseReadsAtOnceAndEveryTwoSeconds() {
        var schedule = CallReadingSchedule()

        XCTAssertEqual(
            plan(&schedule, at: 100, mic: true),
            CallReadingSchedule.Plan(step: .read, next: at(102))
        )
        XCTAssertEqual(
            plan(&schedule, at: 101, mic: true),
            CallReadingSchedule.Plan(step: nil, next: at(102))
        )
        XCTAssertEqual(
            plan(&schedule, at: 102, mic: true),
            CallReadingSchedule.Plan(step: .read, next: at(104))
        )
    }

    /// A recording is when the end of a call matters, so it is read for as
    /// long as one runs, whatever the mic listener says.
    func testARecordingIsReadEveryTwoSecondsEvenWithTheMicIdle() {
        var schedule = CallReadingSchedule()

        XCTAssertEqual(
            plan(&schedule, at: 0, recording: true),
            CallReadingSchedule.Plan(step: .read, next: at(2))
        )
        XCTAssertEqual(
            plan(&schedule, at: 2, recording: true, others: false),
            CallReadingSchedule.Plan(step: .read, next: at(4))
        )
    }

    /// Nobody holds the mic and a call is still being followed: a muted
    /// call whose app closed the mic is still a call while its audio plays,
    /// so it is read every two seconds, as it was, until the watcher says it
    /// is over. Then nothing.
    func testACallBeingFollowedIsReadWithTheMicFreeUntilItEnds() {
        var schedule = CallReadingSchedule()
        _ = plan(&schedule, at: 0, mic: true, call: true)

        XCTAssertEqual(
            plan(&schedule, at: 1, call: true),
            CallReadingSchedule.Plan(step: nil, next: at(2))
        )
        XCTAssertEqual(
            plan(&schedule, at: 2, call: true),
            CallReadingSchedule.Plan(step: .read, next: at(4))
        )
        XCTAssertEqual(
            plan(&schedule, at: 600, call: true),
            CallReadingSchedule.Plan(step: .read, next: at(602))
        )
        XCTAssertEqual(
            plan(&schedule, at: 632, call: false),
            CallReadingSchedule.Plan(step: nil, next: nil)
        )
    }

    /// A take of dictation, with no call anywhere: the mic comes back and
    /// the reader is gone with it.
    func testTheMicLetGoWithNoCallStopsAtOnce() {
        var schedule = CallReadingSchedule()
        _ = plan(&schedule, at: 0, mic: true)

        XCTAssertEqual(
            plan(&schedule, at: 0.5),
            CallReadingSchedule.Plan(step: nil, next: nil)
        )
    }

    /// The listener cannot tell our mic from anyone else's, and pre-roll
    /// holds ours for as long as the app runs. When the last read found
    /// nobody but us, the next one waits ten seconds instead of two.
    func testTheMicHeldByUsAloneIsReadRarely() {
        var schedule = CallReadingSchedule()
        _ = plan(&schedule, at: 0, mic: true)

        XCTAssertEqual(
            plan(&schedule, at: 2, mic: true, others: false),
            CallReadingSchedule.Plan(step: nil, next: at(10))
        )
        XCTAssertEqual(
            plan(&schedule, at: 10, mic: true, others: false),
            CallReadingSchedule.Plan(step: .read, next: at(20))
        )
        // that read found zoom on the mic beside us: every two again.
        XCTAssertEqual(
            plan(&schedule, at: 12, mic: true, others: true),
            CallReadingSchedule.Plan(step: .read, next: at(14))
        )
    }

    /// A call being followed is read closely, even when its app has let go
    /// of the mic and only ours is open: the watcher is timing its end.
    func testACallBeingFollowedIsReadEveryTwoSecondsWhateverHoldsTheMic() {
        var schedule = CallReadingSchedule()
        _ = plan(&schedule, at: 0, mic: true, call: true)

        XCTAssertEqual(
            plan(&schedule, at: 2, mic: true, call: true, others: false),
            CallReadingSchedule.Plan(step: .read, next: at(4))
        )
    }

    /// Stopped is stopped: the next time the mic is taken starts afresh and
    /// reads at once, however soon that is.
    func testAfterStoppingTheNextUseOfTheMicReadsAtOnce() {
        var schedule = CallReadingSchedule()
        _ = plan(&schedule, at: 0, mic: true)
        _ = plan(&schedule, at: 0.5)

        XCTAssertEqual(
            plan(&schedule, at: 1, mic: true),
            CallReadingSchedule.Plan(step: .read, next: at(3))
        )
    }
}
