import XCTest

@MainActor
final class LiveTranscriptModelTests: XCTestCase {
    private func line(
        id: UUID,
        speaker: LiveLine.Speaker = .them,
        at seconds: Int,
        _ text: String,
        confirmed: Bool = false
    ) -> LiveLine {
        LiveLine(
            id: id,
            speaker: speaker,
            at: .seconds(seconds),
            text: text,
            isConfirmed: confirmed
        )
    }

    // MARK: - appending

    func testUpsertingNewLinesKeepsTheOrderTheyArrivedIn() {
        let model = LiveTranscriptModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        model.upsert(line(id: first, at: 1, "one"))
        model.upsert(line(id: second, at: 2, "two"))
        model.upsert(line(id: third, at: 3, "three"))

        XCTAssertEqual(model.lines.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(model.lines.map(\.id), [first, second, third])
    }

    func testAStartingTranscriptIsEmpty() {
        XCTAssertTrue(LiveTranscriptModel().lines.isEmpty)
    }

    // MARK: - revising

    /// Whisper streams the same line twice — a tentative tail, then the
    /// confirmed text. The second arrival must replace the first, not sit
    /// under it as a duplicate sentence.
    func testUpsertReplacesTheLineWithTheSameID() {
        let model = LiveTranscriptModel()
        let id = UUID()

        model.upsert(line(id: id, at: 4, "we should probably"))
        model.upsert(
            line(id: id, at: 4, "we should probably ship it.", confirmed: true)
        )

        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines[0].text, "we should probably ship it.")
        XCTAssertTrue(model.lines[0].isConfirmed)
    }

    /// A revision is not a new line: confirming something said a minute ago
    /// must not drag it to the bottom of the panel.
    func testReplacingALineLeavesItWhereItWasSaid() {
        let model = LiveTranscriptModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        model.upsert(line(id: first, at: 1, "one"))
        model.upsert(line(id: second, at: 2, "two"))
        model.upsert(line(id: third, at: 3, "three"))
        model.upsert(line(id: first, at: 1, "one, revised", confirmed: true))

        XCTAssertEqual(
            model.lines.map(\.text),
            ["one, revised", "two", "three"]
        )
        XCTAssertEqual(model.lines.map(\.id), [first, second, third])
    }

    func testRevisingCanChangeTheSpeakerWithoutSplittingTheLine() {
        let model = LiveTranscriptModel()
        let id = UUID()

        model.upsert(line(id: id, speaker: .them, at: 8, "hello"))
        model.upsert(
            line(id: id, speaker: .you, at: 8, "hello", confirmed: true)
        )

        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines[0].speaker, .you)
    }

    // MARK: - clearing

    func testClearEmptiesTheTranscript() {
        let model = LiveTranscriptModel()
        model.upsert(line(id: UUID(), at: 1, "one"))
        model.upsert(line(id: UUID(), at: 2, "two"))

        model.clear()

        XCTAssertTrue(model.lines.isEmpty)
    }

    func testClearingAnEmptyTranscriptIsNotAnError() {
        let model = LiveTranscriptModel()
        model.clear()

        XCTAssertTrue(model.lines.isEmpty)
    }

    /// The next meeting starts at line one, not line four hundred.
    func testALineCanBeAddedAgainAfterClearing() {
        let model = LiveTranscriptModel()
        let id = UUID()
        model.upsert(line(id: id, at: 1, "one"))
        model.clear()
        model.upsert(line(id: id, at: 1, "one"))

        XCTAssertEqual(model.lines.count, 1)
    }

    // MARK: - the clock

    func testTheHeaderClockDropsHoursUntilThereAreSome() {
        XCTAssertEqual(LiveTranscriptModel.clockText(.seconds(0)), "00:00")
        XCTAssertEqual(LiveTranscriptModel.clockText(.seconds(9)), "00:09")
        XCTAssertEqual(LiveTranscriptModel.clockText(.seconds(754)), "12:34")
        XCTAssertEqual(LiveTranscriptModel.clockText(.seconds(3_599)), "59:59")
        XCTAssertEqual(
            LiveTranscriptModel.clockText(.seconds(3_723)),
            "1:02:03"
        )
    }

    func testALineStampIsAlwaysTheSameWidth() {
        XCTAssertEqual(LiveTranscriptModel.stampText(.seconds(0)), "00:00:00")
        XCTAssertEqual(
            LiveTranscriptModel.stampText(.seconds(432)),
            "00:07:12"
        )
        XCTAssertEqual(
            LiveTranscriptModel.stampText(.seconds(3_723)),
            "01:02:03"
        )
    }

    /// Sub-second offsets truncate rather than round up, so a line at 0.9 s
    /// does not claim to have been said at one second.
    func testStampsTruncateTowardTheSecondTheLineBeganIn() {
        XCTAssertEqual(
            LiveTranscriptModel.stampText(.milliseconds(1_900)),
            "00:00:01"
        )
        XCTAssertEqual(LiveTranscriptModel.clockText(.milliseconds(900)), "00:00")
    }
}
