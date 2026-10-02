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
