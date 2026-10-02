import XCTest

/// the watcher's half that can be tested with strings: finding our words
/// again in a bounded read around where we put them, following them from
/// read to read, and never asking for more of the field than that.
@MainActor
final class SpanFollowerTests: XCTestCase {
    // MARK: - finding our words again

    private func locate(
        _ inserted: String,
        in window: String,
        at expectedStart: Int,
        reachesFieldEnd: Bool = false
    ) -> String? {
        SpanLocator.locate(
            inserted,
            in: window,
            expectedStart: expectedStart,
            reachesFieldEnd: reachesFieldEnd
        )?.text
    }

    func testUntouchedWordsAreFoundWhereWePutThem() {
        XCTAssertEqual(
            locate("Send it to jaz.dev", in: "hi sam. Send it to jaz.dev and the", at: 8),
            "Send it to jaz.dev"
        )
    }

    /// the first and last words hold still while you fix one between them.
    func testAWordFixedBetweenTheAnchorsIsReadBack() {
        XCTAssertEqual(
            locate(
                "I watched Android dictates on the train.",
                in: "ok. I watched Andrew Tate's on the train. then",
                at: 4
            ),
            "I watched Andrew Tate's on the train"
        )
    }

    /// a fix inside the last word leaves the word's other half as anchor.
    func testAFixInsideTheLastWordKeepsItsTailAsAnchor() {
        XCTAssertEqual(
            locate("Send it to jaz.gg.", in: "hi. Send it to jass.gg. bye", at: 4),
            "Send it to jass.gg"
        )
    }

    /// you fixed the last word itself, and nothing follows it: the field's
    /// end is where our words end.
    func testTheLastWordFixedAtTheEndOfTheFieldRunsToTheEnd() {
        XCTAssertEqual(
            locate("Parse the jason", in: "hi. Parse the JSON", at: 4, reachesFieldEnd: true),
            "Parse the JSON"
        )
    }

    /// ...but with your own text after it there is no telling where ours
    /// stops, so the dictation is given up on.
    func testTheLastWordFixedWithTextAfterItIsGivenUpOn() {
        XCTAssertNil(locate("Parse the jason", in: "hi. Parse the JSON then ship", at: 4))
    }

    /// you fixed the first word: we still know where we put it.
    func testTheFirstWordFixedIsFoundWhereWePutIt() {
        XCTAssertEqual(
            locate("Jason parse it.", in: "hi. JSON parse it. more", at: 4),
            "JSON parse it"
        )
    }

    /// sent, cleared, or rewritten: neither anchor is there.
    func testWordsThatAreGoneAreGivenUpOn() {
        XCTAssertNil(locate("Send it to jaz.dev", in: "", at: 0))
        XCTAssertNil(locate("Send it to jaz.dev", in: "something else entirely", at: 0))
    }

    /// one word, fixed, is both anchors gone: there is nothing of ours left
    /// to be sure the word in that spot is the one we wrote.
    func testAOneWordDictationFixedIsGivenUpOn() {
        XCTAssertNil(locate("jason", in: "JSON", at: 0, reachesFieldEnd: true))
        XCTAssertEqual(locate("jason", in: "jason", at: 0, reachesFieldEnd: true), "jason")
    }

    /// you typed a few words ahead of ours: they moved, and are found.
    func testWordsPushedAlongByTypingBeforeThemAreFound() {
        XCTAssertEqual(
            locate("Send it to jaz.dev", in: "hi sam, please Send it to jass.dev", at: 7),
            "Send it to jass.dev"
        )
    }

    /// "the" is everywhere: the one nearest where we put it is ours.
    func testARepeatedWordAnchorsNearestWhereWePutIt() {
        XCTAssertEqual(
            locate("the dog barked", in: "the cat sat. the dog barked", at: 13),
            "the dog barked"
        )
    }

    // MARK: - the follower reads only our span, and a margin

    func testTheFollowerWaitsForThePasteToLand() {
        let field = FakeField("hi. ")
        var follower = SpanFollower(inserted: "Send it to jaz.dev")

        XCTAssertEqual(follower.read(field), .notLanded)

        field.type("Send it to jaz.dev")
        XCTAssertEqual(follower.read(field), .reads("Send it to jaz.dev"))
    }

    func testAFixReadsBack() {
        let field = FakeField("hi. Send it to jaz.dev")
        var follower = SpanFollower(inserted: "Send it to jaz.dev")
        _ = follower.read(field)

        field.text = "hi. Send it to jass.dev"

        XCTAssertEqual(follower.read(field), .reads("Send it to jass.dev"))
    }

    /// the whole point of the rule: a long document around our words is
    /// never asked for, before the paste lands or after.
    func testNothingBeyondTheMarginIsEverAskedFor() {
        let before = String(repeating: "private words. ", count: 20)
        let after = String(repeating: " more private.", count: 20)
        let field = FakeField(before + "Send it to jaz.dev")
        var follower = SpanFollower(inserted: "Send it to jaz.dev")
        _ = follower.read(field)
        field.text = before + "Send it to jass.dev" + after
        field.caret = (before as NSString).length

        XCTAssertEqual(follower.read(field), .reads("Send it to jass.dev"))

        let start = (before as NSString).length
        let end = start + ("Send it to jaz.dev" as NSString).length
        XCTAssertFalse(field.asked.isEmpty)
        for range in field.asked {
            XCTAssertGreaterThanOrEqual(range.location, start - SpanFollower.margin)
            XCTAssertLessThanOrEqual(NSMaxRange(range), end + SpanFollower.margin)
        }
    }

    /// sent, cleared, or deleted: our words are gone.
    func testAClearedFieldIsGone() {
        let field = FakeField("Send it to jaz.dev")
        var follower = SpanFollower(inserted: "Send it to jaz.dev")
        _ = follower.read(field)

        field.text = ""

        XCTAssertEqual(follower.read(field), .gone)
    }

    /// typing ahead of our words moves them, and the follower moves with them:
    /// two pushes of thirty are more than one margin, but never at once.
    func testTheFollowerFollowsWordsPushedAlongByTyping() {
        let field = FakeField("Send it to jaz.dev")
        var follower = SpanFollower(inserted: "Send it to jaz.dev")
        _ = follower.read(field)
        let thirty = String(repeating: "a", count: 29) + " "

        field.text = thirty + field.text
        XCTAssertEqual(follower.read(field), .reads("Send it to jaz.dev"))
        field.text = thirty + field.text
        XCTAssertEqual(follower.read(field), .reads("Send it to jaz.dev"))
    }
}

/// a text field as AX sees it: a caret, a length, and text by range — with
/// every range asked for written down.
@MainActor
private final class FakeField: SpanReader {
    var text: String
    var caret: Int
    private(set) var asked: [NSRange] = []

    init(_ text: String) {
        self.text = text
        caret = (text as NSString).length
    }

    func type(_ more: String) {
        text += more
        caret = (text as NSString).length
    }

    func caretLocation() -> Int? {
        caret
    }

    func characterCount() -> Int? {
        (text as NSString).length
    }

    func text(in range: NSRange) -> String? {
        asked.append(range)
        guard NSMaxRange(range) <= (text as NSString).length else {
            return nil
        }
        return (text as NSString).substring(with: range)
    }
}
