import XCTest

final class CleanerTests: XCTestCase {
    func testDictionarySubstitutionUsesExactReplacementCasing() {
        let cleaner = DeterministicCleaner(
            entries: [
                DictionaryEntry(wrong: "gpt", right: "GPT"),
                DictionaryEntry(wrong: "iphone", right: "iPhone"),
            ]
        )

        XCTAssertEqual(
            cleaner.clean("use gPt with an IPHONE"),
            "Use GPT with an iPhone"
        )
    }

    func testWordBoundariesProtectPartialMatches() {
        let cleaner = DeterministicCleaner(
            entries: [DictionaryEntry(wrong: "gpt", right: "GPT")]
        )

        XCTAssertEqual(cleaner.clean("umbrella gptx"), "Umbrella gptx")
    }

    func testFillersAndFollowingCommasAreRemoved() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("um, I uh think erm, this uhm works"),
            "I think this works"
        )
    }

    func testConservativeFillerListKeepsLikeAndYouKnow() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("like, you know, this works"),
            "Like, you know, this works"
        )
    }

    func testWhitespaceIsCollapsedAndRemovedBeforePunctuation() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("  hello   ,   world  !  "),
            "Hello, world!"
        )
    }

    func testOnlyFirstCharacterIsCapitalizedWithoutAppendingPeriod() {
        let cleaner = DeterministicCleaner()

        XCTAssertEqual(
            cleaner.clean("hello. second sentence"),
            "Hello. second sentence"
        )
    }

    func testEmptyStringRemainsEmpty() {
        XCTAssertEqual(DeterministicCleaner().clean(""), "")
    }

    func testDictionaryOnlyPassPreservesRawCommandText() {
        let substituter = DictionarySubstituter(
            entries: [DictionaryEntry(wrong: "gpt", right: "GPT")]
        )

        XCTAssertEqual(
            substituter.apply(to: "  type um, gPt   EXACTLY  "),
            "  type um, GPT   EXACTLY  "
        )
    }
}
