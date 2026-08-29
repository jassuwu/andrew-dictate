import XCTest

final class MeetingTranscriptTests: XCTestCase {
    private var parent: URL!
    private let tz = TimeZone(identifier: "Asia/Kolkata")!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - naming

    func testSlugKeepsLettersAndDigitsOnly() {
        XCTAssertEqual(MeetingTranscriptFile.slug("zoom.us"), "zoom-us")
        XCTAssertEqual(MeetingTranscriptFile.slug("Google Chrome"), "google-chrome")
        XCTAssertEqual(MeetingTranscriptFile.slug("  --Teams 2--  "), "teams-2")
        XCTAssertEqual(MeetingTranscriptFile.slug("!!!"), "meeting")
    }

    func testFileURLHasNoSpacesAndAMonthFolder() {
        let url = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        XCTAssertEqual(
            url.path,
            parent.appendingPathComponent("meetings/2026-08/2026-08-29-1402-zoom.md").path
        )
        XCTAssertFalse(url.path.contains(" "))
    }

    func testFileURLStepsAsideWhenTheNameIsTaken() throws {
        let first = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = MeetingTranscriptFile.fileURL(
            in: parent, started: started(), app: "zoom", timeZone: tz)
        XCTAssertEqual(second.lastPathComponent, "2026-08-29-1402-zoom-2.md")
    }

    // MARK: - markdown

    func testACompleteTranscriptRendersFrontMatterAndTurns() {
        let transcript = MeetingTranscript(
            app: "zoom",
            started: started(),
            duration: .seconds(6120),
            engine: "whisper-large-v3-turbo",
            gaps: [],
            recovered: false,
            turns: [
                .init(speaker: .you, at: .seconds(4), text: "hi, can you hear me?"),
                .init(speaker: .them(1), at: .seconds(9), text: "yes. the deploy is blocked."),
                .init(speaker: .them(nil), at: .seconds(724), text: "let's move on."),
            ]
        )
        let expected = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        duration_s: 6120
        engine: whisper-large-v3-turbo
        complete: true
        gaps: []
        recovered: false
        ---

        [00:00:04] you: hi, can you hear me?

        [00:00:09] them 1: yes. the deploy is blocked.

        [00:12:04] them: let's move on.

        """
        XCTAssertEqual(MeetingTranscriptFile.markdown(transcript, timeZone: tz), expected)
    }

    func testAnIncompleteTranscriptSaysWhereTheHolesAre() {
        let transcript = MeetingTranscript(
            app: "chrome",
            started: started(),
            duration: .seconds(100),
            engine: "whisper-large-v3-turbo",
            gaps: [.init(began: .seconds(41.25), ended: .seconds(63))],
            recovered: true,
            turns: [.init(speaker: .you, at: .zero, text: "hello")]
        )
        let expected = """
        ---
        app: chrome
        started: 2026-08-29T14:02:11+05:30
        duration_s: 100
        engine: whisper-large-v3-turbo
        complete: false
        gaps:
        - [41.2, 63.0]
        recovered: true
        ---

        > 1 gap — audio was lost between 00:00:41 and 00:01:03

        [00:00:00] you: hello

        """
        XCTAssertEqual(MeetingTranscriptFile.markdown(transcript, timeZone: tz), expected)
    }

    // MARK: - round trip

    func testWriteThenSummaryReadsTheFrontMatterBack() throws {
        let transcript = MeetingTranscript(
            app: "teams",
            started: started(),
            duration: .seconds(3601),
            engine: "whisper-large-v3-turbo",
            gaps: [
                .init(began: .seconds(1), ended: .seconds(2)),
                .init(began: .seconds(5), ended: .seconds(9)),
            ],
            recovered: false,
            turns: []
        )
        let url = try MeetingTranscriptFile.write(transcript, in: parent, timeZone: tz)
        let summary = try MeetingTranscriptFile.summary(of: url)
        XCTAssertEqual(summary.fileURL, url)
        XCTAssertEqual(summary.app, "teams")
        XCTAssertEqual(summary.started.timeIntervalSince1970,
                       started().timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(summary.duration, .seconds(3601))
        XCTAssertFalse(summary.complete)
        XCTAssertEqual(summary.gapCount, 2)
        XCTAssertFalse(summary.recovered)
    }

    func testSummaryOfAFileWithoutFrontMatterThrows() throws {
        let url = parent.appendingPathComponent("notes.md")
        try "just some notes".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MeetingTranscriptFile.summary(of: url))
    }

    func testListAllIsNewestFirstAndSkipsJunk() throws {
        let older = MeetingTranscript(
            app: "zoom", started: started(), duration: .seconds(1),
            engine: "e", gaps: [], recovered: false, turns: [])
        let newer = MeetingTranscript(
            app: "slack", started: started().addingTimeInterval(86_400 * 40),
            duration: .seconds(1), engine: "e", gaps: [], recovered: false, turns: [])
        _ = try MeetingTranscriptFile.write(older, in: parent, timeZone: tz)
        _ = try MeetingTranscriptFile.write(newer, in: parent, timeZone: tz)
        let junk = parent.appendingPathComponent("meetings/2026-08/todo.md")
        try "- [ ] nothing".write(to: junk, atomically: true, encoding: .utf8)

        let all = MeetingTranscriptFile.listAll(in: parent)
        XCTAssertEqual(all.map(\.app), ["slack", "zoom"])
    }

    func testListAllOfAMissingFolderIsEmpty() {
        XCTAssertEqual(
            MeetingTranscriptFile.listAll(
                in: parent.appendingPathComponent("nope")).count, 0)
    }

    // MARK: -

    private func started() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 29
        components.hour = 14; components.minute = 2; components.second = 11
        components.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
