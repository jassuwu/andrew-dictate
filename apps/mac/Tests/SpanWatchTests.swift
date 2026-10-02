import XCTest

/// the watcher's half that can be tested with strings: finding our words
/// again in a bounded read around where we put them, and never asking for
/// more of the field than that.
final class SpanWatchTests: XCTestCase {
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
}
