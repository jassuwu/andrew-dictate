import XCTest

/// The meetings half of history, and the action on a row whose audio is
/// still kept: `transcribe again with ▸` and the models that are installed.
/// Judged by what the row would show in each state.
@MainActor
final class MeetingsListAgainTests: XCTestCase {
    private var dir: URL!
    private var started: [(transcript: URL, model: SpeechModel)] = []
    private var installed: Set<SpeechModel> = [.whisperLargeV3, .parakeetV3]

    /// thursday 2026-10-01 10:00 UTC.
    private let thursday = Date(timeIntervalSince1970: 1_790_848_800)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-list-again-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        started = []
        installed = [.whisperLargeV3, .parakeetV3]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var kept: KeptAudio {
        KeptAudio(root: dir.appendingPathComponent("meeting-audio"))
    }

    // MARK: - what the row offers

    /// every model that is on this mac, in the order the settings lists
    /// them — the one that wrote the transcript included, since doing it
    /// again with the same one is a retry.
    func testARowWhoseAudioIsKeptOffersTheInstalledModels() async throws {
        installed = [.parakeetV3, .whisperLargeV3Turbo, .whisperLargeV3]
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom, model: .parakeetV3)
        let model = list([zoom])

        XCTAssertEqual(
            model.again(for: zoom), .offer([.whisperLargeV3, .whisperLargeV3Turbo, .parakeetV3]))
    }

    func testARowWithNoAudioOffersNothing() {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let model = list([zoom])

        XCTAssertEqual(model.again(for: zoom), .none)
    }

    /// it is the audio that makes it possible, so the action goes when the
    /// audio does.
    func testTheActionIsGoneOnceTheAudioIs() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = list([zoom])
        XCTAssertNotEqual(model.again(for: zoom), .none)

        model.deleteAudio(of: zoom)

        XCTAssertEqual(model.again(for: zoom), .none)
    }

    /// a pane that was never told how to do it has nothing to offer.
    func testAPaneWithNoWayToTranscribeAgainOffersNothing() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = MeetingsListModel(keptAudio: kept, load: { [zoom] })

        XCTAssertEqual(model.again(for: zoom), .none)
    }

    // MARK: - when it cannot be done now

    func testItWaitsWhileAMeetingIsBeingRecorded() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = list([zoom])

        model.isRecording = true

        XCTAssertEqual(model.again(for: zoom), .wait("recording"))
        model.isRecording = false
        XCTAssertNotEqual(model.again(for: zoom), .wait("recording"))
    }

    /// the one being redone says so, and every other row waits its turn.
    func testWhileOneIsRunningItsRowSaysSoAndTheOthersWait() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let chrome = meeting("2026-10-01-1500-chrome.md")
        try await keepAudio(for: zoom)
        try await keepAudio(for: chrome)
        let model = list([zoom, chrome])

        model.transcribingAgain = zoom.fileURL

        XCTAssertEqual(model.again(for: zoom), .running)
        XCTAssertEqual(model.again(for: chrome), .wait("one at a time"))
    }

    /// a row with no audio has no action to wait on.
    func testARowWithNoAudioStaysAbsentWhileSomethingRuns() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        let model = list([zoom])

        model.isRecording = true
        model.transcribingAgain = URL(fileURLWithPath: "/tmp/other.md")

        XCTAssertEqual(model.again(for: zoom), .none)
    }

    func testWithNoModelInstalledItSaysSo() async throws {
        installed = []
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = list([zoom])

        XCTAssertEqual(model.again(for: zoom), .wait("no model installed"))
    }

    // MARK: - choosing one

    func testChoosingAModelStartsItForThatMeeting() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = list([zoom])

        model.transcribeAgain(zoom, with: .whisperLargeV3)

        XCTAssertEqual(started.map(\.transcript), [zoom.fileURL])
        XCTAssertEqual(started.map(\.model), [.whisperLargeV3])
    }

    /// a menu that was open when the world changed does not start anything
    /// the row would not have offered.
    func testChoosingWhileItWaitsOrWithAModelThatIsNotThereDoesNothing() async throws {
        let zoom = meeting("2026-10-01-1402-zoom.md")
        try await keepAudio(for: zoom)
        let model = list([zoom])

        model.transcribeAgain(zoom, with: .whisperLargeV3Turbo)
        model.isRecording = true
        model.transcribeAgain(zoom, with: .whisperLargeV3)

        XCTAssertTrue(started.isEmpty)
    }

    // MARK: -

    private func list(_ meetings: [MeetingSummary]) -> MeetingsListModel {
        MeetingsListModel(
            keptAudio: kept,
            installedModels: { [installed] in installed },
            transcribeAgain: { [weak self] transcript, model in
                self?.started.append((transcript, model))
            },
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

    /// two seconds of its audio, kept until you delete it.
    private func keepAudio(
        for meeting: MeetingSummary, model: SpeechModel = .parakeetV3
    ) async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "zoom", started: thursday, engine: model.rawValue, model: model))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(MeetingAudioChunk(
            you: Array(repeating: 0.05, count: 32_000),
            them: Array(repeating: 0.05, count: 32_000), at: .zero))
        XCTAssertTrue(kept.keep(handle, label: .init(
            transcript: meeting.fileURL, started: thursday, model: model, until: nil)))
    }
}
