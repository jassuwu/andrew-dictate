import XCTest

final class RecurringMishearingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    func testAnEmptyArchiveHasNothingToAsk() {
        XCTAssertTrue(scan([]).isEmpty)
    }

    func testAWordHasToTurnUpInTwoDictations() {
        XCTAssertTrue(
            scan([dictation("going to kunur", minutesAgo: 10)]).isEmpty
        )

        XCTAssertEqual(
            scan([
                dictation("going to kunur", minutesAgo: 10),
                dictation("kunur again", minutesAgo: 5),
            ]).map(\.heard),
            ["kunur"]
        )
    }

    /// Saying one word twice in a sentence is not a pattern.
    func testTwiceInOneDictationIsStillOneDictation() {
        XCTAssertTrue(
            scan([dictation("kunur and kunur again", minutesAgo: 5)]).isEmpty
        )
    }

    func testAWordYouAlreadyTaughtItIsNeverAskedAbout() {
        let candidates = scan(
            twice("kunur"),
            dictionary: [DictionaryEntry(wrong: "  KUNUR ", right: "Coonoor")]
        )

        XCTAssertTrue(
            candidates.isEmpty,
            "the taught side is matched the way the substitution matches it"
        )
    }

    func testNotAMistakeNeverComesBack() {
        XCTAssertTrue(
            scan(twice("swiggy"), dismissed: ["swiggy"]).isEmpty
        )
    }

    func testTheSpellCheckerDecidesWhatCountsAsAWord() {
        let candidates = scan(
            twice("kunur about the deploy"),
            isSuspect: { $0 == "kunur" }
        )

        XCTAssertEqual(candidates.map(\.heard), ["kunur"])
    }

    func testAWordOlderThanThirtyDaysHasBeenLetGo() {
        let old = 31.0 * 24 * 60
        XCTAssertTrue(
            scan([
                dictation("going to kunur", minutesAgo: old),
                dictation("kunur again", minutesAgo: old + 5),
            ]).isEmpty
        )
    }

    func testTheMostRepeatedWordComesFirst() {
        let candidates = scan([
            dictation("kunur swiggy", minutesAgo: 30),
            dictation("swiggy", minutesAgo: 20),
            dictation("kunur swiggy", minutesAgo: 10),
        ])

        XCTAssertEqual(candidates.map(\.heard), ["swiggy", "kunur"])
        XCTAssertEqual(candidates.first?.count, 3)
    }

    func testItAsksAboutEightWordsAtMost() {
        let words = [
            "alpha", "bravo", "charlie", "delta", "echo",
            "foxtrot", "golf", "hotel", "india", "juliet",
        ].joined(separator: " ")

        XCTAssertEqual(scan(twice(words)).count, 8)
    }

    // MARK: - the time you spelled it out loud

    func testSpellingItOutLoudPreFillsTheRow() {
        let candidates = scan([
            dictation("c o o n o o r", minutesAgo: 30),
            dictation("take them to kunur this weekend", minutesAgo: 20),
            dictation("maybe kunur then", minutesAgo: 5),
        ])

        XCTAssertEqual(candidates.map(\.heard), ["kunur"])
        XCTAssertEqual(candidates.first?.spelledOut, "coonoor")
    }

    func testALineOfSingleLettersIsNotSevenWordsItGotWrong() {
        let candidates = scan(twice("c o o n o o r"))

        XCTAssertTrue(candidates.isEmpty)
    }

    func testASpellOutAnHourEarlierIsNotAboutThisWord() {
        let candidates = scan([
            dictation("c o o n o o r", minutesAgo: 90),
            dictation("take them to kunur this weekend", minutesAgo: 20),
            dictation("maybe kunur then", minutesAgo: 5),
        ])

        XCTAssertEqual(candidates.first?.heard, "kunur")
        XCTAssertNil(candidates.first?.spelledOut)
    }

    func testTheConsonantSkeletonForgivesTheObviousSubstitutions() {
        XCTAssertEqual(
            RecurringMishearings.skeleton("coonoor"),
            RecurringMishearings.skeleton("kunur")
        )
        XCTAssertEqual(
            RecurringMishearings.skeleton("phase"),
            RecurringMishearings.skeleton("faze")
        )
        XCTAssertNotEqual(
            RecurringMishearings.skeleton("kunur"),
            RecurringMishearings.skeleton("deploy")
        )
    }

    // MARK: - helpers

    private func scan(
        _ dictations: [Dictation],
        dictionary: [DictionaryEntry] = [],
        dismissed: Set<String> = [],
        isSuspect: (String) -> Bool = { _ in true }
    ) -> [RecurringMishearings.Candidate] {
        RecurringMishearings.scan(
            dictations,
            dictionary: dictionary,
            dismissed: dismissed,
            isSuspect: isSuspect,
            now: now
        )
    }

    private func dictation(
        _ heard: String,
        minutesAgo: Double
    ) -> Dictation {
        Dictation(
            startedAt: now.addingTimeInterval(-minutesAgo * 60),
            heard: heard,
            inserted: heard,
            engine: "v2"
        )
    }

    private func twice(_ heard: String) -> [Dictation] {
        [
            dictation(heard, minutesAgo: 10),
            dictation(heard, minutesAgo: 5),
        ]
    }
}
