import XCTest

@MainActor
final class WordFixerViewModelTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: storeURL.deletingLastPathComponent()
        )
        super.tearDown()
    }

    private func model(
        _ transcript: String = "send the jason to cypher d and cc darsh"
    ) -> (WordFixerViewModel, DictionaryStore) {
        let store = DictionaryStore(fileURL: storeURL)
        return (
            WordFixerViewModel(transcript: transcript, store: store),
            store
        )
    }

    func testNothingIsSelectedToStartWith() {
        let (model, _) = model()

        XCTAssertNil(model.selectedPhrase)
        XCTAssertFalse(model.canSave)
    }

    func testTappingAWordSelectsJustThatWord() {
        let (model, _) = model()
        model.tap(2)

        XCTAssertEqual(model.selectedPhrase, "jason")
    }

    /// How "cypher d" becomes one entry rather than two.
    func testTappingTheNextWordGrowsTheSelection() {
        let (model, _) = model()
        model.tap(4)
        model.tap(5)

        XCTAssertEqual(model.selectedPhrase, "cypher d")
    }

    func testItGrowsBackwardsToo() {
        let (model, _) = model()
        model.tap(5)
        model.tap(4)

        XCTAssertEqual(model.selectedPhrase, "cypher d")
    }

    func testTappingSomewhereElseStartsOver() {
        let (model, _) = model()
        model.tap(4)
        model.tap(5)
        model.tap(0)

        XCTAssertEqual(model.selectedPhrase, "send")
    }

    func testAHalfFinishedSelectionCannotBeSaved() {
        let (model, _) = model()
        model.tap(2)
        XCTAssertFalse(model.canSave, "no replacement typed yet")

        model.replacement = "   "
        XCTAssertFalse(model.canSave, "whitespace is not a replacement")

        model.replacement = "JSON"
        XCTAssertTrue(model.canSave)
    }

    // MARK: - saving

    func testSavingWritesAnEntryThatActuallyFires() {
        let (model, store) = model()
        model.tap(2)
        model.replacement = "JSON"
        model.save()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(
            DeterministicCleaner(entries: store.entries)
                .clean("send the jason to cypher d and cc darsh"),
            "Send the JSON to cypher d and cc darsh."
        )
    }

    func testSavingClearsTheSelectionSoTheNextFixStartsClean() {
        let (model, _) = model()
        model.tap(2)
        model.replacement = "JSON"
        model.save()

        XCTAssertNil(model.selectedPhrase)
        XCTAssertEqual(model.replacement, "")
    }

    func testASavedWordShowsWhatItBecameAndCannotBeFixedTwice() {
        let (model, _) = model()
        model.tap(4)
        model.tap(5)
        model.replacement = "CypherD"
        model.save()

        XCTAssertEqual(model.saved[4], "CypherD")
        XCTAssertEqual(model.saved[5], "CypherD", "both words of the phrase")

        model.tap(4)
        XCTAssertNil(model.selectedPhrase, "already fixed")
    }

    func testSeveralFixesFromOneTranscriptAllLand() {
        let (model, store) = model()
        for (first, last, right) in [(2, 2, "JSON"), (4, 5, "CypherD"), (8, 8, "Darsh")] {
            model.tap(first)
            if last != first { model.tap(last) }
            model.replacement = right
            model.save()
        }

        XCTAssertEqual(
            DeterministicCleaner(entries: store.entries)
                .clean("send the jason to cypher d and cc darsh"),
            "Send the JSON to CypherD and cc Darsh."
        )
    }

    /// SPEC §4. A save that did not happen must not look like one that did.
    func testAFailedSaveSaysSoAndKeepsTheSelection() {
        let store = DictionaryStore(fileURL: storeURL)
        // A directory where the file needs to be: writes cannot succeed.
        try? FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        let model = WordFixerViewModel(
            transcript: "send the jason",
            store: store
        )
        model.tap(2)
        model.replacement = "JSON"
        model.save()

        XCTAssertNotNil(model.failure)
        XCTAssertEqual(model.selectedPhrase, "jason", "your work is not thrown away")
        XCTAssertTrue(model.saved.isEmpty, "nothing claims to have been saved")
    }
}
