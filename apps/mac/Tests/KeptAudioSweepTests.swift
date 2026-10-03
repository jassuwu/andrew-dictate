import XCTest

/// Kept audio past its date is deleted without asking when the app
/// launches, and once a day while it runs — and a launch pays nothing for
/// meetings to do it: one look at one folder, no coordinator built.
@MainActor
final class KeptAudioSweepTests: XCTestCase {
    private var dir: URL!
    private var wall: FakeWall!
    private var coordinatorsBuilt = 0

    /// 2026-10-02 07:52:31 UTC: when the audio was kept.
    private let keptAt = Date(timeIntervalSince1970: 1_790_927_551)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-audio-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wall = FakeWall(keptAt)
        coordinatorsBuilt = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var kept: KeptAudio {
        KeptAudio(root: dir.appendingPathComponent("meeting-audio"), now: { [wall] in wall!.now })
    }

    func testALaunchSweepsWhatIsDueWithoutBuildingTheMeetings() async throws {
        try await keepAudio(for: "2026-10-01-0900-meeting.md", until: keptAt.addingTimeInterval(-1))
        try await keepAudio(for: "2026-10-02-0900-meeting.md", until: keptAt.addingTimeInterval(60))
        try await keepAudio(for: "2026-09-01-0900-meeting.md", until: nil)
        let meetings = holder()

        meetings.launch(
            setUp: false, transcripts: dir.appendingPathComponent("transcripts"),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            recoveryDelay: .zero, keptAudio: kept)
        await waitFor { kept.all().count == 2 }

        XCTAssertEqual(
            kept.all().map(\.label.transcript.lastPathComponent).sorted(),
            ["2026-09-01-0900-meeting.md", "2026-10-02-0900-meeting.md"])
        XCTAssertEqual(coordinatorsBuilt, 0)
    }

    /// The app is left running: what falls due is swept on the next round,
    /// without a meeting or a relaunch to set it off.
    func testWhileTheAppRunsWhatFallsDueIsSweptOnTheNextRound() async throws {
        try await keepAudio(for: "2026-10-02-0900-meeting.md", until: keptAt.addingTimeInterval(86_400))
        let meetings = holder()
        meetings.launch(
            setUp: false, transcripts: dir.appendingPathComponent("transcripts"),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            recoveryDelay: .zero, keptAudio: kept, sweepEvery: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(kept.all().count, 1)

        wall.advance(by: 86_400)
        await waitFor { kept.all().isEmpty }

        XCTAssertEqual(kept.all().count, 0)
        XCTAssertEqual(coordinatorsBuilt, 0)
    }

    /// Audio kept until you delete it is deleted from its transcript's row.
    /// One whose transcript was moved, renamed or deleted outside the app
    /// has no row left to delete it from: the sweep gives it a week, and
    /// then it goes like any other. The one whose transcript is still there
    /// still waits for you.
    func testAudioKeptUntilYouDeleteItWhoseTranscriptIsGoneGetsAWeekThenGoes() async throws {
        let here = "2026-10-02-0900-meeting.md"
        let gone = "2026-10-01-0900-meeting.md"
        try writeTranscript(here)
        try await keepAudio(for: here, until: nil)
        try await keepAudio(for: gone, until: nil)

        kept.sweep()

        let until = Dictionary(
            uniqueKeysWithValues: kept.all().map { ($0.label.transcript.lastPathComponent, $0.label.until) })
        XCTAssertEqual(until.count, 2)
        XCTAssertEqual(until[here], .some(nil), "its transcript is there")
        XCTAssertEqual(until[gone], keptAt.addingTimeInterval(KeptAudio.keptWithoutItsTranscriptFor))
        XCTAssertEqual(KeptAudio.keptWithoutItsTranscriptFor, 7 * 86_400)

        wall.advance(by: KeptAudio.keptWithoutItsTranscriptFor - 1)
        kept.sweep()
        XCTAssertEqual(kept.all().count, 2, "not yet")

        wall.advance(by: 1)
        kept.sweep()
        XCTAssertEqual(kept.all().map(\.label.transcript.lastPathComponent), [here])
    }

    // MARK: -

    private var transcripts: URL {
        dir.appendingPathComponent("transcripts/meetings/2026-10")
    }

    private func writeTranscript(_ name: String) throws {
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data("---\n".utf8).write(to: transcripts.appendingPathComponent(name))
    }

    /// Two seconds of a meeting's audio, kept for `transcript` until `until`.
    private func keepAudio(for transcript: String, until: Date?) async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "meeting", started: keptAt, engine: "parakeetV3", model: .parakeetV3))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(MeetingAudioChunk(
            you: Array(repeating: 0.05, count: 32_000),
            them: Array(repeating: 0.05, count: 32_000), at: .zero))
        XCTAssertTrue(kept.keep(handle, label: .init(
            transcript: dir.appendingPathComponent("transcripts/meetings/2026-10/\(transcript)"),
            started: keptAt, model: .parakeetV3, until: until)))
    }

    private func holder() -> LazyMeetings {
        let dir = dir!
        return LazyMeetings(
            coordinator: { [weak self] in
                self?.coordinatorsBuilt += 1
                return MeetingCoordinator(
                    source: SilentSource(),
                    makeTranscriber: { _ in throw NoModel() },
                    diarizer: NoDiarizer(),
                    spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
                    hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
                    preferences: {
                        MeetingPreferences(
                            folder: dir.appendingPathComponent("transcripts"),
                            hook: nil, model: .parakeetV3)
                    }
                )
            },
            notifier: { MeetingNudgeNotifier() }
        )
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

private final class FakeWall: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

private struct NoModel: Error {}

private struct SilentSource: MeetingAudioSource {
    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        AsyncStream { $0.finish() }
    }

    func rebuild() async throws {}
    func stop() async {}
}

private struct NoDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns
    }
}
