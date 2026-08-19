import XCTest

final class PipelineRunTests: XCTestCase {
    private let entries = [
        DictionaryEntry(wrong: "jason", right: "JSON")
    ]

    func testTranscriptionStageIsAlwaysOnAndPassesTextThrough() {
        let results = PipelineRun.throughCleaner(
            "um hello comma world",
            selection: PipelineSelection(),
            entries: entries
        )

        let heard = results[0]
        XCTAssertEqual(heard.stage, .transcription)
        XCTAssertTrue(heard.isEnabled)
        XCTAssertEqual(heard.output, "um hello comma world")
        XCTAssertFalse(heard.changedAnything)
    }

    func testDisablingCleanupShowsTheRawTranscriptUntouched() {
        let raw = "um hello comma world"
        var selection = PipelineSelection()
        selection.deterministicEnabled = false

        let results = PipelineRun.throughCleaner(
            raw,
            selection: selection,
            entries: entries
        )

        let cleanup = results[1]
        XCTAssertEqual(cleanup.stage, .deterministic)
        XCTAssertFalse(cleanup.isEnabled)
        XCTAssertEqual(cleanup.output, raw)
        XCTAssertFalse(cleanup.changedAnything)
    }

    func testCleanupStageReportsThatItChangedTheText() {
        let results = PipelineRun.throughCleaner(
            "um hello comma world",
            selection: PipelineSelection(),
            entries: entries
        )

        let cleanup = results[1]
        XCTAssertTrue(cleanup.isEnabled)
        XCTAssertTrue(cleanup.changedAnything)
        XCTAssertNotEqual(cleanup.output, cleanup.input)
    }

    func testCleanupThatChangesNothingIsNotAFailure() {
        let results = PipelineRun.throughCleaner(
            "Hello.",
            selection: PipelineSelection(),
            entries: []
        )

        let cleanup = results[1]
        XCTAssertTrue(cleanup.isEnabled)
        XCTAssertNil(cleanup.unavailableReason)
        XCTAssertFalse(cleanup.changedAnything)
    }

    func testPolishIsHandedWhateverTheLastStageProduced() {
        let results = PipelineRun.throughCleaner(
            "um hello comma world",
            selection: PipelineSelection(),
            entries: entries
        )

        XCTAssertEqual(
            PipelineRun.polishInput(from: results),
            results[1].output
        )
    }

    func testUnavailablePolishPassesTextThroughAndSaysWhy() {
        let stage = PipelineRun.polishResult(
            input: "Hello, world.",
            output: nil,
            isEnabled: true,
            unavailableReason: "needs macOS 26"
        )

        XCTAssertEqual(stage.output, "Hello, world.")
        XCTAssertFalse(stage.changedAnything)
        XCTAssertEqual(stage.unavailableReason, "needs macOS 26")
    }

    func testOnlyPolishCanBeSwitchedOff() {
        var selection = PipelineSelection()
        selection.toggle(.transcription)
        XCTAssertTrue(selection.isEnabled(.transcription))

        selection.toggle(.polish)
        XCTAssertTrue(selection.isEnabled(.polish))
        selection.toggle(.deterministic)
        XCTAssertFalse(selection.isEnabled(.deterministic))

        XCTAssertTrue(PipelineStage.transcription.isAlwaysOn)
        XCTAssertTrue(PipelineStage.deterministic.isAlwaysOn)
        XCTAssertFalse(PipelineStage.polish.isAlwaysOn)
    }

    func testTheOpeningSampleGivesEveryStageSomethingToDo() {
        let results = PipelineRun.throughCleaner(
            PipelineSample.text,
            selection: PipelineSelection(),
            entries: []
        )

        XCTAssertTrue(results[1].changedAnything)
    }
}
