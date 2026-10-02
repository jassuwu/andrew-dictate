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

    // MARK: - speech that was never read

    /// A hundred seconds of their speech, and the engine gave up on
    /// twenty-one of them: a fifth is the most that may go missing.
    func testMoreThanAFifthOfASideUnreadIsThin() {
        let them = CoverageCheck.Side(speech: .seconds(100), read: .seconds(79), words: 200)

        XCTAssertEqual(
            CoverageCheck.verdict(you: Self.quiet, them: them, farSideLoud: .seconds(100)),
            .thin(reason: "some of what was said could not be read"))
    }

    func testAFifthOfASideUnreadIsStillCovered() {
        let you = CoverageCheck.Side(speech: .seconds(100), read: .seconds(80), words: 200)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .pass)
    }

    /// Under ten seconds of speech is a cough and a "yes": too little to
    /// hold a share of it against the transcript.
    func testASideWithUnderTenSecondsOfSpeechIsNotJudgedOnWhatWentUnread() {
        let you = CoverageCheck.Side(speech: .seconds(9.9), read: .zero, words: 0)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .pass)
    }

    func testTenSecondsOfSpeechWithNoneOfItReadIsThin() {
        let you = CoverageCheck.Side(speech: .seconds(10), read: .zero, words: 0)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .thin(reason: "some of what was said could not be read"))
    }

    // MARK: -

    private static let quiet = CoverageCheck.Side(speech: .zero, read: .zero, words: 0)
}
