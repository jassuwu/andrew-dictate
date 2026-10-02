import XCTest

/// the learner sits beside the word diff and the mishearing scan: the text
/// we inserted, what you made of it, and the swaps you made before — in,
/// and out a dictionary entry or nothing.
final class CorrectionLearnerTests: XCTestCase {
    /// the app's pipeline with cleanup on, which is what every entry here is
    /// tried in.
    private let plainCleaner: ([DictionaryEntry]) -> DeterministicCleaner = {
        DeterministicCleaner(entries: $0)
    }
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

    // MARK: - the entry fires on what the engine heard

    private func entry(
        heard: String,
        inserted: String,
        edited: String,
        dictionary: [DictionaryEntry] = []
    ) -> DictionaryEntry? {
        guard let swap = CorrectionLearner.swaps(
            inserted: inserted,
            edited: edited
        ).first else {
            return nil
        }
        return CorrectionLearner.entry(
            for: swap,
            heard: heard,
            dictionary: dictionary,
            cleaner: plainCleaner
        )
    }

    /// the dictionary reads the engine's words before the parsers do, so
    /// an entry keyed on "jaz.dev" would never fire on "jaz dot dev" — the
    /// fault ADR 0024 exists to rule out. the entry is keyed on what was
    /// heard.
    func testTheEntryIsKeyedOnTheWordsTheEngineHeard() {
        let learned = entry(
            heard: "send it to jaz dot dev",
            inserted: "Send it to jaz.dev",
            edited: "Send it to jass.dev"
        )

        XCTAssertEqual(learned?.wrong, "jaz dot dev")
        XCTAssertEqual(learned?.right, "jass.dev")
        XCTAssertEqual(
            DeterministicCleaner(entries: learned.map { [$0] } ?? [])
                .clean("send it to jaz dot dev"),
            "Send it to jass.dev"
        )
    }

    /// the engine wrote the domain itself: the entry is the word as heard.
    func testAWordTheEngineWroteAsIsIsKeyedAsIs() {
        let learned = entry(
            heard: "send it to jaz.gg",
            inserted: "Send it to jaz.gg.",
            edited: "Send it to jass.gg."
        )

        XCTAssertEqual(learned?.wrong, "jaz.gg")
        XCTAssertEqual(learned?.right, "jass.gg")
    }

    func testAMultiWordSwapBecomesOneEntry() {
        let learned = entry(
            heard: "i watched android dictates on the train",
            inserted: "I watched Android dictates on the train.",
            edited: "I watched Andrew Tate's on the train."
        )

        XCTAssertEqual(learned?.wrong, "android dictates")
        XCTAssertEqual(learned?.right, "Andrew Tate's")
    }

    /// a word one of your own entries wrote is yours, not the engine's: the
    /// learner never writes a rule over a rule you made.
    func testAWordYourOwnEntryWroteTeachesNothing() {
        XCTAssertNil(entry(
            heard: "parse the jay son first",
            inserted: "Parse the jason first.",
            edited: "Parse the JSON first.",
            dictionary: [DictionaryEntry(wrong: "jay son", right: "jason")]
        ))
    }

    // MARK: - only on the second identical swap

    private func learner() -> CorrectionLearner {
        CorrectionLearner()
    }

    /// one dictation of "send it to jaz dot dev", fixed to `fix`.
    private func fixJaz(
        _ learner: inout CorrectionLearner,
        to fix: String,
        dictionary: [DictionaryEntry] = [],
        neverLearn: Set<LearningKey> = []
    ) -> [DictionaryEntry] {
        learner.watch(heard: "send it to jaz dot dev", inserted: "Send it to jaz.dev")
        return learner.settle(
            edited: "Send it to \(fix)",
            dictionary: dictionary,
            neverLearn: neverLearn,
            cleaner: plainCleaner
        )
    }

    func testTheFirstFixTeachesNothingAndTheSecondIdenticalOneIsLearned() {
        var learner = learner()

        XCTAssertEqual(fixJaz(&learner, to: "jass.dev"), [])
        let learned = fixJaz(&learner, to: "jass.dev")

        XCTAssertEqual(learned.map(\.wrong), ["jaz dot dev"])
        XCTAssertEqual(learned.map(\.right), ["jass.dev"])
        XCTAssertEqual(learned.map(\.learned), [true])
    }

    /// the span is read again every time it goes quiet: one dictation is
    /// one vote however often it is read.
    func testOneDictationReadTwiceIsStillOneFix() {
        var learner = learner()
        learner.watch(heard: "send it to jaz dot dev", inserted: "Send it to jaz.dev")

        XCTAssertEqual(learner.settle(edited: "Send it to jass.dev", dictionary: [], neverLearn: [], cleaner: plainCleaner), [])
        XCTAssertEqual(learner.settle(edited: "Send it to jass.dev", dictionary: [], neverLearn: [], cleaner: plainCleaner), [])
    }

    /// "jas.dev" on the way to "jass.dev" was a pause in your typing, not a
    /// fix: a dictation counts as the last thing you left it as.
    func testAFixChangedBeforeTheDictationEndsCountsOnlyAsItsLastVersion() {
        var learner = learner()
        learner.watch(heard: "send it to jaz dot dev", inserted: "Send it to jaz.dev")
        _ = learner.settle(edited: "Send it to jas.dev", dictionary: [], neverLearn: [], cleaner: plainCleaner)
        _ = learner.settle(edited: "Send it to jass.dev", dictionary: [], neverLearn: [], cleaner: plainCleaner)

        XCTAssertEqual(fixJaz(&learner, to: "jas.dev"), [])
        XCTAssertEqual(fixJaz(&learner, to: "jass.dev").map(\.right), ["jass.dev"])
    }

    func testTwoDifferentFixesOfOneWordDoNotAddUp() {
        var learner = learner()

        XCTAssertEqual(fixJaz(&learner, to: "jass.dev"), [])
        XCTAssertEqual(fixJaz(&learner, to: "jazz.dev"), [])
    }

    /// undo is for good: the same pair fixed twice more stays unlearned.
    func testAPairYouUndidIsNeverLearnedAgain() {
        var learner = learner()
        let undone: Set<LearningKey> = [LearningKey(wrong: "jaz dot dev", right: "jass.dev")]

        XCTAssertEqual(fixJaz(&learner, to: "jass.dev", neverLearn: undone), [])
        XCTAssertEqual(fixJaz(&learner, to: "jass.dev", neverLearn: undone), [])
    }
}
