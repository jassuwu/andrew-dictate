import XCTest

/// the learner sits beside the word diff and the mishearing scan: the text
/// we inserted, what you made of it, and the swaps you made before — in,
/// and out a dictionary entry or nothing.
final class CorrectionLearnerTests: XCTestCase {
    // MARK: - sounds like

    /// the mishearings the ticket was written for: a name the engine turned
    /// into words it knows, a domain spelled as it sounds, an acronym said
    /// as a name.
    func testMishearingsSoundAlike() {
        XCTAssertTrue(SoundAlike.soundsAlike("Android dictates", "Andrew Tate's"))
        XCTAssertTrue(SoundAlike.soundsAlike("jaz.gg", "jass.gg"))
        XCTAssertTrue(SoundAlike.soundsAlike("jason", "JSON"))
        XCTAssertTrue(SoundAlike.soundsAlike("cloud code", "Claude Code"))
    }

    /// a different word that means much the same is you choosing it.
    func testSynonymsAndChangedMindsDoNotSoundAlike() {
        XCTAssertFalse(SoundAlike.soundsAlike("big", "large"))
        XCTAssertFalse(SoundAlike.soundsAlike("ship", "release"))
        XCTAssertFalse(SoundAlike.soundsAlike("today", "tomorrow"))
    }

    // MARK: - only swaps

    private func swaps(_ inserted: String, _ edited: String) -> [[String]] {
        CorrectionLearner.swaps(inserted: inserted, edited: edited)
            .map { [$0.from, $0.to] }
    }

    /// the sentence-ending stop the cleaner added belongs to the sentence,
    /// not the word: an entry carrying it would never fire.
    func testAWordSwappedForOneThatSoundsLikeItIsASwap() {
        XCTAssertEqual(
            swaps("Send it to jaz.gg.", "Send it to jass.gg."),
            [["jaz.gg", "jass.gg"]]
        )
        XCTAssertEqual(
            swaps("I watched Android dictates on the train.", "I watched Andrew Tate's on the train."),
            [["Android dictates", "Andrew Tate's"]]
        )
        XCTAssertEqual(
            swaps("Parse the jason first.", "Parse the JSON first."),
            [["jason", "JSON"]]
        )
    }

    /// words you add or take away are your writing, not a mishearing.
    func testAddedAndDeletedWordsAreNotSwaps() {
        XCTAssertEqual(swaps("Send it to jass.", "Send it to jass today."), [])
        XCTAssertEqual(swaps("Send it to jass now.", "Send it now."), [])
    }

    /// more than three words in one place is a rewrite.
    func testARewriteIsNotASwap() {
        XCTAssertEqual(
            swaps(
                "We should ship the build on friday.",
                "We should push all of it to next week."
            ),
            []
        )
    }

    /// the engine heard the word right; you just wanted it written another
    /// way.
    func testCaseAndPunctuationOnlyChangesAreNotSwaps() {
        XCTAssertEqual(swaps("Try the parakeet model.", "Try the Parakeet model."), [])
        XCTAssertEqual(swaps("Its fine, ship it.", "It's fine, ship it."), [])
        XCTAssertEqual(swaps("Send it to jass.gg.", "Send it to jass.gg!"), [])
    }

    func testAWordSwappedForASynonymIsNotASwap() {
        XCTAssertEqual(swaps("That is a big change.", "That is a large change."), [])
        XCTAssertEqual(swaps("Ship it today.", "Release it today."), [])
        XCTAssertEqual(swaps("Ship it today.", "Ship it tomorrow."), [])
    }

    /// "their" for "there" sounds alike and is grammar: a rule that turned
    /// every "there" into "their" would wreck far more than it fixed.
    func testCommonWordsSwappedForEachOtherAreGrammarNotMishearings() {
        XCTAssertEqual(swaps("Put it over there.", "Put it over their."), [])
        XCTAssertEqual(swaps("Better then before.", "Better than before."), [])
        XCTAssertEqual(swaps("It is in the box.", "It is on the box."), [])
    }

    /// "larger" for "large" sounds alike and is still you changing the word.
    func testAnInflectionIsNotASwap() {
        XCTAssertEqual(swaps("Pick the large one.", "Pick the larger one."), [])
        XCTAssertEqual(swaps("Ship the build.", "Shipped the build."), [])
    }
}
