import XCTest

/// The one time a transcript file changes after it is written: you asked for
/// the meeting to be transcribed again. What the file keeps of the meeting is
/// read back from its front matter, and the file is replaced where it is.
final class MeetingTranscriptAgainTests: XCTestCase {
    private var parent: URL!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-08-18 02:23:20 in kolkata.
    private let started = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcript-again-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - reading the meeting back

    func testTheFrontMatterReadsBackWhatTheMeetingWas() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [
                    .init(began: .seconds(41.2), ended: .seconds(63)),
                    .init(began: .seconds(600), ended: .seconds(604.5)),
                ],
                recovered: true),
            in: parent, timeZone: kolkata)

        let header = try MeetingTranscriptFile.header(of: url)

        XCTAssertEqual(header.app, "zoom")
        XCTAssertEqual(header.started, started)
        XCTAssertEqual(header.timeZone.secondsFromGMT(), 19_800)
        XCTAssertEqual(header.duration, .seconds(6_120))
        XCTAssertEqual(header.gaps, [
            .init(began: .seconds(41.2), ended: .seconds(63)),
            .init(began: .seconds(600), ended: .seconds(604.5)),
        ])
        XCTAssertTrue(header.recovered)
        XCTAssertFalse(header.complete)
    }

    func testAFileWithNoGapsHasNoneAndASaidWholeFileIsComplete() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [], recovered: false), in: parent, timeZone: kolkata)

        let header = try MeetingTranscriptFile.header(of: url)

        XCTAssertEqual(header.gaps, [])
        XCTAssertFalse(header.recovered)
        XCTAssertTrue(header.complete)
    }

    func testAnOffsetOfZeroIsWrittenAsAZ() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [], recovered: false), in: parent, timeZone: utc)

        let header = try MeetingTranscriptFile.header(of: url)

        XCTAssertEqual(header.timeZone.secondsFromGMT(), 0)
    }

    func testAFileWithNoFrontMatterCannotBeRead() throws {
        let url = parent.appendingPathComponent("notes.md")
        try "# notes\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MeetingTranscriptFile.header(of: url))
    }

    // MARK: - replacing it

    /// the body and the engine are the new reading's; the file is where it
    /// was, with nothing left beside it.
    func testReplacingAFileRewritesItAtTheSamePath() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [], recovered: false), in: parent, timeZone: kolkata)
        let folder = url.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)

        try MeetingTranscriptFile.replace(
            at: url,
            with: meeting(
                gaps: [], recovered: false, engine: "whisperLargeV3",
                turns: [.init(speaker: .them(1), at: .seconds(3), text: "namaste")]),
            timeZone: kolkata)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("engine: whisperLargeV3\n"), text)
        XCTAssertTrue(text.contains("speakers: [them 1]\n"), text)
        XCTAssertTrue(text.contains("words: 1\n"), text)
        XCTAssertTrue(text.contains("[00:00:03] them 1: namaste\n"), text)
        XCTAssertFalse(text.contains("hello"), text)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            before.sorted())
    }

    /// the meeting's own lines are the file's to keep: read them, write them
    /// in the offset they were written in, and they come back the same —
    /// whatever zone the mac is in now.
    func testWhatTheMeetingWasIsWrittenBackExactlyAsItWas() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [.init(began: .seconds(41.96), ended: .seconds(63))],
                recovered: true),
            in: parent, timeZone: kolkata)
        let before = try frontMatter(of: url)
        let header = try MeetingTranscriptFile.header(of: url)

        try MeetingTranscriptFile.replace(
            at: url,
            with: MeetingTranscript(
                app: header.app, started: header.started, duration: header.duration,
                engine: "whisperLargeV3", gaps: header.gaps, recovered: header.recovered,
                turns: [.init(speaker: .you, at: .seconds(1), text: "again")]),
            timeZone: header.timeZone)

        let after = try frontMatter(of: url)
        for key in ["app", "started", "ended", "duration_s", "recovered"] {
            XCTAssertEqual(after[key], before[key], key)
        }
        XCTAssertEqual(after["gaps"], before["gaps"])
        XCTAssertEqual(after["engine"], "whisperLargeV3")
    }

    func testTheReplacementIsNotReadableByOtherUsers() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [], recovered: false), in: parent, timeZone: kolkata)

        try MeetingTranscriptFile.replace(
            at: url, with: meeting(gaps: [], recovered: false, engine: "whisperLargeV3"),
            timeZone: kolkata)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// a file you threw away while it was being made again is not a file to
    /// bring back: there is nothing there to replace, and nothing is made.
    func testReplacingAFileThatIsGoneThrowsAndMakesNothing() throws {
        let url = parent.appendingPathComponent("meetings/2026-08/gone.md")

        XCTAssertThrowsError(try MeetingTranscriptFile.replace(
            at: url, with: meeting(gaps: [], recovered: false), timeZone: kolkata))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// the note an agent reads first promised a file that never changes;
    /// it says when one does.
    func testTheNoteSaysTheFileChangesOnlyWhenTheMeetingIsTranscribedAgain() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [], recovered: false), in: parent, timeZone: kolkata)

        let note = try String(
            contentsOf: url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(MeetingTranscriptFile.noteName),
            encoding: .utf8)

        XCTAssertTrue(
            note.contains("not changed after it is written, unless you have the meeting transcribed again"),
            note)
        XCTAssertFalse(note.contains("never changed"), note)
    }

    // MARK: -

    private func meeting(
        gaps: [MeetingSession.Gap],
        recovered: Bool,
        engine: String = "parakeetV3",
        turns: [MeetingTurn] = [.init(speaker: .you, at: .seconds(4), text: "hello there")]
    ) -> MeetingTranscript {
        MeetingTranscript(
            app: "zoom", started: started, duration: .seconds(6_120), engine: engine,
            gaps: gaps, recovered: recovered, turns: turns)
    }

    /// the front matter as written, key to value; a key with a list is its
    /// lines joined.
    private func frontMatter(of url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var fields: [String: String] = [:]
        var key: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("- "), let key {
                fields[key, default: ""] += "|" + line
            } else if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon])
                fields[key!] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }
}
