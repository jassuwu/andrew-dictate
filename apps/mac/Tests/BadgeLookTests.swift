import XCTest

/// which look the menu bar badge wears, one test per rung of the ladder.
/// the inputs are plain values so the order can be argued with here,
/// without a coordinator or a meeting behind it.
final class BadgeLookTests: XCTestCase {
    func testNothingOnIsTheBareBadge() {
        XCTAssertEqual(
            BadgeLook(needsSetup: false, isDictating: false, meeting: .none),
            .idle
        )
    }

    /// a missing grant or model means nothing else can be reached, so
    /// the setup dot wins over every take and every meeting.
    func testASetupGapOutranksEverything() {
        for meeting in BadgeLook.Meeting.allCases {
            for isDictating in [false, true] {
                XCTAssertEqual(
                    BadgeLook(
                        needsSetup: true,
                        isDictating: isDictating,
                        meeting: meeting
                    ),
                    .needsSetup,
                    "\(meeting), dictating: \(isDictating)"
                )
            }
        }
    }

    /// a meeting losing its audio is the next most urgent thing on the
    /// mac: it stays on the badge until it clears, take or no take.
    func testAMeetingProblemOutranksDictating() {
        for isDictating in [false, true] {
            XCTAssertEqual(
                BadgeLook(
                    needsSetup: false,
                    isDictating: isDictating,
                    meeting: .problem
                ),
                .meetingProblem,
                "dictating: \(isDictating)"
            )
        }
    }

    /// dictation is refused while a meeting records (ADR 0023), so the two
    /// never meet in practice; if they ever did, the meeting is the one
    /// that runs for an hour and needs the badge.
    func testARecordingMeetingOutranksDictating() {
        for isDictating in [false, true] {
            XCTAssertEqual(
                BadgeLook(
                    needsSetup: false,
                    isDictating: isDictating,
                    meeting: .recording
                ),
                .recordingMeeting,
                "dictating: \(isDictating)"
            )
        }
    }
}
