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

    // MARK: - speech read into too few words

    /// An hour of their talk read, and it came to a handful of words: the
    /// engine heard it and wrote nearly nothing down.
    func testAnHourOfReadSpeechThatCameToAHandfulOfWordsIsThin() {
        let them = CoverageCheck.Side(speech: .seconds(3_600), read: .seconds(3_600), words: 12)

        XCTAssertEqual(
            CoverageCheck.verdict(you: Self.quiet, them: them, farSideLoud: .seconds(3_600)),
            .thin(reason: "far fewer words than the talk that was heard"))
    }

    /// Half a word a second is the least: talk runs at two or three.
    func testHalfAWordASecondOfReadSpeechIsStillCovered() {
        let you = CoverageCheck.Side(speech: .seconds(60), read: .seconds(60), words: 30)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .pass)
    }

    func testJustUnderHalfAWordASecondIsThin() {
        let you = CoverageCheck.Side(speech: .seconds(60), read: .seconds(60), words: 29)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .thin(reason: "far fewer words than the talk that was heard"))
    }

    /// Under thirty seconds read is a few short answers, and a few short
    /// answers can be "yeah", "mm", "right".
    func testUnderThirtySecondsOfReadSpeechIsNotJudgedOnItsWords() {
        let you = CoverageCheck.Side(speech: .seconds(29.9), read: .seconds(29.9), words: 0)

        XCTAssertEqual(
            CoverageCheck.verdict(you: you, them: Self.quiet, farSideLoud: .zero),
            .pass)
    }

    // MARK: -

    private static let quiet = CoverageCheck.Side(speech: .zero, read: .zero, words: 0)
}
