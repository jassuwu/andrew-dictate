import XCTest

/// The site's meeting scene ends with one markdown file. The file it shows,
/// for every point a visitor can press stop at, is in one file the site
/// reads. This builds the same turns with the real writer and compares, so
/// the page shows the layout the app writes and an agent can read both the
/// same way.
final class DemoMeetingTests: XCTestCase {
    private struct Call: Decodable {
        let app: String
        let started: String
        let timeZone: String
        let engine: String
        let file: String
        let lines: [Line]
        let stops: [Stop]
    }

    private struct Line: Decodable {
        let speaker: String
        let at: Int
        let text: String
    }

    private struct Stop: Decodable {
        let duration: Int
        let saved: String
        let markdown: String
    }

    /// apps/mac/Tests/ → apps/site/src/demo/meeting.json
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("site/src/demo/meeting.json")

    private func call() throws -> Call {
        try JSONDecoder().decode(Call.self, from: Data(contentsOf: Self.file))
    }

    private func speaker(_ label: String) throws -> MeetingTurn.Speaker {
        if label == "you" { return .you }
        if label == "them" { return .them(nil) }
        let number = try XCTUnwrap(
            Int(label.dropFirst("them ".count)), "no such speaker: \(label)")
        return .them(number)
    }

    private func transcript(_ call: Call, lines count: Int) throws -> MeetingTranscript {
        let started = try XCTUnwrap(ISO8601DateFormatter().date(from: call.started))
        return MeetingTranscript(
            app: call.app,
            started: started,
            duration: .seconds(call.stops[count - 1].duration),
            engine: call.engine,
            gaps: [],
            recovered: false,
            turns: try call.lines.prefix(count).map {
                MeetingTurn(speaker: try speaker($0.speaker), at: .seconds($0.at), text: $0.text)
            }
        )
    }

    func testThereIsAStopForEveryLine() throws {
        let call = try call()
        XCTAssertGreaterThanOrEqual(call.lines.count, 6)
        XCTAssertEqual(call.stops.count, call.lines.count)
        XCTAssertNotNil(MeetingModel(rawValue: call.engine), "not a meeting model: \(call.engine)")
    }

    func testEveryFileTheSceneShowsIsWhatTheWriterWrites() throws {
        let call = try call()
        let zone = try XCTUnwrap(TimeZone(identifier: call.timeZone))
        for count in 1...call.stops.count {
            XCTAssertEqual(
                MeetingTranscriptFile.markdown(try transcript(call, lines: count), timeZone: zone),
                call.stops[count - 1].markdown,
                "stopped after \(count) lines"
            )
        }
    }

    func testTheSavedLineAndTheFileNameAreTheAppsOwn() throws {
        let call = try call()
        let zone = try XCTUnwrap(TimeZone(identifier: call.timeZone))
        for stop in call.stops {
            XCTAssertEqual(stop.saved, "saved · \(Duration.seconds(stop.duration).spoken)")
        }
        let started = try XCTUnwrap(ISO8601DateFormatter().date(from: call.started))
        let url = MeetingTranscriptFile.fileURL(
            in: FileManager.default.temporaryDirectory
                .appendingPathComponent("demo-meeting-\(UUID().uuidString)"),
            started: started, app: call.app, timeZone: zone)
        XCTAssertEqual(url.lastPathComponent, call.file)
    }
}
