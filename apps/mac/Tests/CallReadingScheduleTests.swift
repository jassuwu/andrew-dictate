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
}
