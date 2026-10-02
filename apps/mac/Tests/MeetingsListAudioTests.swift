import XCTest

/// the meetings half of history, and the audio kept beside a meeting: the
/// row says it is there and until when, offers to delete it now, and a
/// transcript deleted from here takes its audio with it.
@MainActor
final class MeetingsListAudioTests: XCTestCase {
    private var dir: URL!
    private var trashed: [URL] = []

    /// thursday 2026-10-01 10:00 UTC.
    private let thursday = Date(timeIntervalSince1970: 1_790_848_800)
    /// friday 2026-10-02 14:02 UTC.
    private let fridayAfternoon = Date(timeIntervalSince1970: 1_790_949_720)
    /// saturday 2026-10-10 14:02 UTC: more than a week out.
    private let aWeekOn = Date(timeIntervalSince1970: 1_791_640_920)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-list-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trashed = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var kept: KeptAudio {
        KeptAudio(root: dir.appendingPathComponent("meeting-audio"))
    }

    func testARowWhoseAudioIsKeptForADaySaysUntilWhen() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom, until: fridayAfternoon)
        let model = list([zoom])

        XCTAssertEqual(model.audioNote(for: zoom), "audio until fri 14:02")
    }

    /// a week out, a weekday would be this week's: the date says which.
    func testAudioKeptForMoreThanAWeekSaysTheDate() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom, until: aWeekOn)
        let model = list([zoom])

        XCTAssertEqual(model.audioNote(for: zoom), "audio until 10 oct 14:02")
    }

    func testAThinMeetingsAudioIsSimplyKept() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom, until: nil)
        let model = list([zoom])

        XCTAssertEqual(model.audioNote(for: zoom), "audio kept")
    }

    func testARowWithNoAudioSaysNothingAboutIt() {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let model = list([zoom])

        XCTAssertNil(model.audioNote(for: zoom))
    }

    func testDeleteAudioNowDeletesItAndTheRowStopsSayingSo() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let chrome = meeting("2026-10-01-1500-chrome.md")
        try await keepAudio(for: zoom, until: fridayAfternoon)
        try await keepAudio(for: chrome, until: fridayAfternoon)
        let model = list([zoom, chrome])

        model.deleteAudio(of: zoom)

        XCTAssertNil(model.audioNote(for: zoom))
        XCTAssertEqual(kept.all().map(\.label.transcript), [chrome.fileURL])
        XCTAssertEqual(model.items, [zoom, chrome], "the transcripts stay")
    }

    /// the transcript goes to the trash, where it can be got back; its
    /// audio goes for good, as it would have on its day.
    func testDeletingATranscriptDeletesItsAudio() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let chrome = meeting("2026-10-01-1500-chrome.md")
        try await keepAudio(for: zoom, until: nil)
        try await keepAudio(for: chrome, until: nil)
        let model = list([zoom, chrome])

        model.delete(zoom)

        XCTAssertEqual(trashed, [zoom.fileURL])
        XCTAssertEqual(kept.all().map(\.label.transcript), [chrome.fileURL])
    }

    // MARK: -

    private func list(_ meetings: [MeetingSummary]) -> MeetingsListModel {
        MeetingsListModel(
            keptAudio: kept,
            now: { [thursday] in thursday },
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!,
            trash: { [weak self] in self?.trashed.append($0) },
            load: { meetings })
    }

    private func meeting(_ name: String) -> MeetingSummary {
        MeetingSummary(
            fileURL: dir.appendingPathComponent("docs/meetings/2026-10/\(name)"),
            app: "zoom",
            started: thursday,
            duration: .seconds(600),
            complete: true,
            gapCount: 0,
            recovered: false)
    }

    /// two seconds of its audio, kept until `until`.
    private func keepAudio(for meeting: MeetingSummary, until: Date?) async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "zoom", started: thursday, engine: "parakeetV3", model: .parakeetV3))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(MeetingAudioChunk(
            you: Array(repeating: 0.05, count: 32_000),
            them: Array(repeating: 0.05, count: 32_000), at: .zero))
        XCTAssertTrue(kept.keep(handle, label: .init(
            transcript: meeting.fileURL, started: thursday, model: .parakeetV3, until: until)))
    }
}
