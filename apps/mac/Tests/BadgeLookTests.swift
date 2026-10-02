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
}
