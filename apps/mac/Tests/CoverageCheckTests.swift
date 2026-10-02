import XCTest

/// The coverage check on its own: the numbers a meeting ends with, and
/// whether its transcript covers what was said.
final class CoverageCheckTests: XCTestCase {
    func testAMeetingWhereNobodySpokePasses() {
        let silent = CoverageCheck.Side(speech: .zero, read: .zero, words: 0)

        XCTAssertEqual(
            CoverageCheck.verdict(you: silent, them: silent, farSideLoud: .zero),
            .pass)
    }
}
