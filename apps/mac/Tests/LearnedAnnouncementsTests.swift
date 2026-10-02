import XCTest

/// `learned: <word>` is said once, and never lost: an entry learned while
/// the pill can't speak waits for a moment it can.
final class LearnedAnnouncementsTests: XCTestCase {
    private let cypherD = DictionaryEntry(wrong: "cypher d", right: "CypherD", learned: true)
    private let jassGG = DictionaryEntry(wrong: "jaz dot gg", right: "jass.gg", learned: true)

    func testAnEntryLearnedWhileIdleIsSaidAtOnce() {
        var announcements = LearnedAnnouncements()

        announcements.learned(cypherD)

        XCTAssertEqual(
            announcements.due(canSay: true, stillThere: { _ in true }),
            "learned: CypherD"
        )
    }

    /// a meeting, a take, another pill up: it waits, and is said when the
    /// app is quiet again.
    func testAnEntryLearnedWhileBusyWaitsForIdle() {
        var announcements = LearnedAnnouncements()

        announcements.learned(cypherD)

        XCTAssertNil(announcements.due(canSay: false, stillThere: { _ in true }))
        XCTAssertEqual(
            announcements.due(canSay: true, stillThere: { _ in true }),
            "learned: CypherD"
        )
    }

    func testItIsSaidOnce() {
        var announcements = LearnedAnnouncements()
        announcements.learned(cypherD)

        _ = announcements.due(canSay: true, stillThere: { _ in true })

        XCTAssertNil(announcements.due(canSay: true, stillThere: { _ in true }))
    }

    /// nothing here keeps time: a meeting that outlasts the menu's
    /// two-minute undo still ends with the word said.
    func testItWaitsAsLongAsItTakes() {
        var announcements = LearnedAnnouncements()
        announcements.learned(cypherD)

        for _ in 0..<1_000 {
            XCTAssertNil(announcements.due(canSay: false, stillThere: { _ in true }))
        }

        XCTAssertEqual(
            announcements.due(canSay: true, stillThere: { _ in true }),
            "learned: CypherD"
        )
    }

    /// two learned in one meeting are one pill: a second would only
    /// replace the first before it could be read.
    func testTwoLearnedWhileBusyAreSaidTogetherInOrder() {
        var announcements = LearnedAnnouncements()

        announcements.learned(cypherD)
        announcements.learned(jassGG)

        XCTAssertNil(announcements.due(canSay: false, stillThere: { _ in true }))
        XCTAssertEqual(
            announcements.due(canSay: true, stillThere: { _ in true }),
            "learned: CypherD, jass.gg"
        )
    }

    /// undone from the menu, or removed in the dictionary tab, before it
    /// could be said: there is nothing left to announce.
    func testAnEntryTakenOutWhileWaitingIsNotSaid() {
        var announcements = LearnedAnnouncements()
        announcements.learned(cypherD)
        announcements.learned(jassGG)
        let cypherD = cypherD

        XCTAssertEqual(
            announcements.due(canSay: true, stillThere: { $0.id != cypherD.id }),
            "learned: jass.gg"
        )
        XCTAssertNil(announcements.due(canSay: true, stillThere: { _ in true }))
    }

    func testNothingLearnedIsNothingSaid() {
        var announcements = LearnedAnnouncements()

        XCTAssertNil(announcements.due(canSay: true, stillThere: { _ in true }))
    }
}
