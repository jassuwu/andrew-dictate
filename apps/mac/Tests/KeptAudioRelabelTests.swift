import XCTest

/// A meeting transcribed again changes what its kept audio's label says: the
/// model that wrote the transcript now, and sometimes until when. Nothing
/// else about the audio moves.
final class KeptAudioRelabelTests: XCTestCase {
    private var dir: URL!
    /// 2026-10-02 06:52:31 UTC.
    private let started = Date(timeIntervalSince1970: 1_790_923_951)
    private let transcript = URL(fileURLWithPath: "/tmp/docs/meetings/2026-10/2026-10-02-1222-zoom.md")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-audio-relabel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var kept: KeptAudio { KeptAudio(root: dir.appendingPathComponent("meeting-audio")) }

    func testRelabellingSaysTheNewModelAndDateAndLeavesTheRestAlone() async throws {
        try await keepAudio(until: nil)
        let entry = try XCTUnwrap(kept.entry(for: transcript))
        let date = Date(timeIntervalSince1970: 1_791_010_351)

        XCTAssertTrue(kept.relabel(entry, model: .whisperLargeV3, until: date))

        let after = try XCTUnwrap(kept.entry(for: transcript))
        XCTAssertEqual(after.audio, entry.audio, "the audio is the same file")
        XCTAssertEqual(after.label, KeptAudio.Label(
            transcript: transcript, started: started, model: .whisperLargeV3, until: date))
        XCTAssertEqual(kept.all().count, 1)
    }

    /// the date is the sweep's word for when to delete, so a label that
    /// keeps the audio until you delete it says so in the file too.
    func testRelabellingWithNoDateKeepsTheAudioUntilItIsDeleted() async throws {
        try await keepAudio(until: Date(timeIntervalSince1970: 1_791_010_351))
        let entry = try XCTUnwrap(kept.entry(for: transcript))

        XCTAssertTrue(kept.relabel(entry, model: .parakeetV3, until: nil))

        XCTAssertNil(try XCTUnwrap(kept.entry(for: transcript)).label.until)
        let json = try String(
            contentsOf: dir.appendingPathComponent("meeting-audio/\(entry.id).json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"untilDeleted\" : true"), json)
    }

    /// deleted from history while its meeting was being transcribed again:
    /// the label is not written back for audio that is not there.
    func testAudioDeletedMeanwhileIsNotGivenALabelAgain() async throws {
        try await keepAudio(until: nil)
        let entry = try XCTUnwrap(kept.entry(for: transcript))
        kept.deleteAudio(of: transcript)

        XCTAssertFalse(kept.relabel(entry, model: .whisperLargeV3, until: nil))

        let left = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("meeting-audio").path)
        XCTAssertEqual(left, [])
    }

    // MARK: -

    /// two seconds of a meeting's audio, kept for `transcript`.
    private func keepAudio(until: Date?) async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "zoom", started: started, engine: "parakeetV3", model: .parakeetV3))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(MeetingAudioChunk(
            you: Array(repeating: 0.05, count: 32_000),
            them: Array(repeating: 0.05, count: 32_000), at: .zero))
        XCTAssertTrue(kept.keep(handle, label: .init(
            transcript: transcript, started: started, model: .parakeetV3, until: until)))
    }
}
