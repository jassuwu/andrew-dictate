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
}
