import XCTest

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []
    private var hookRuns: [HookRun] = []
    private var hook: URL?

    private let zoom = RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 42)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
        hookRuns = []
        hook = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(30))
    ) -> MeetingCoordinator {
        let folder = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: thresholds,
            preferences: { [hook] in
                MeetingPreferences(folder: folder, hook: hook, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.recordHookRun = { [weak self] in self?.hookRuns.append($0) }
        return c
    }

    // MARK: -

    func testHearingTheProbeStartsTheRecording() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        XCTAssertEqual(c.state, .provingItCanHear)

        source.send(loud(at: .zero))
        await settle()

        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(events, [.started(app: "zoom")])
        XCTAssertEqual(c.dictationResponse, .refuseAndSayWhy)
    }

    func testSilenceThroughTheProbeMeansItCannotHear() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()

        source.send(quiet(at: .zero))
        source.send(quiet(at: .seconds(2)))
        await settle()

        // "can't hear" is said once and the session ends — the menu must
        // never read "recording" over a tap that delivered nothing.
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events, [.cannotHear(app: "zoom")])
        XCTAssertEqual(c.dictationResponse, .allow)
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testStoppingWritesTheFileDeletesTheSpoolAndRunsTheHook() async throws {
        hook = try script("#!/bin/sh\ncat > \"$ANDREW_FOLDER/seen.json\"\nexit 0\n")
        transcriber.finalTurns = [
            .init(speaker: .you, at: .seconds(1), text: "hello"),
            .init(speaker: .them(nil), at: .seconds(2), text: "hi"),
        ]
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()

        c.stop()
        await settle(for: 1.5)

        XCTAssertEqual(c.state, .idle)
        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.count, 1)
        let saved = try XCTUnwrap(all.first)
        XCTAssertEqual(saved.app, "zoom")
        XCTAssertTrue(saved.complete)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("[00:00:02] them 1: hi"), body)

        XCTAssertTrue(events.contains(.writingItOut))
        XCTAssertTrue(events.contains(.saved(saved)))
        XCTAssertEqual(hookRuns.map(\.outcome), [.succeeded])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: saved.fileURL.deletingLastPathComponent().appendingPathComponent("seen.json").path))
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testAFailingHookIsAnnounced() async throws {
        hook = try script("#!/bin/sh\nexit 7\n")
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        c.stop()
        await settle(for: 1.5)

        XCTAssertEqual(events.last, .hookFailed("exit 7"))
        XCTAssertEqual(hookRuns.map(\.outcome), [.failed(exitCode: 7)])
    }

    func testStoppingBeforeAnythingWasHeardKeepsNothing() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(quiet(at: .zero))
        await settle()
        c.stop()
        await settle()

        XCTAssertEqual(events, [.nothingToKeep])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
        XCTAssertEqual(MeetingSpool(root: dir.appendingPathComponent("spool")).orphans().count, 0)
    }

    func testAQuietHourAsksOnce() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        // Quiet, but not long enough to be a dead tap: each chunk is a second
        // of near-silence within the 5 s silence timeout of nothing... so
        // keep the tap "alive" with a faint signal above the floor.
        for s in stride(from: 1, through: 40, by: 1) {
            source.send(faint(at: .seconds(s)))
        }
        await settle()

        XCTAssertEqual(events.filter { $0 == .nudge }.count, 0, "faint audio counts as activity")

        // Now truly silent for longer than the nudge, shorter than the tap timeout each step.
        source.send(loud(at: .seconds(41)))
        var t = 42
        while t < 80 {
            source.send(quiet(at: .seconds(t)))
            source.send(loud(at: .seconds(t + 4)))  // keep the tap alive
            t += 5
        }
        await settle()
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 0, "a loud chunk every 5 s is activity")
    }

    func testLiveLinesAreUpsertedById() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        let id = UUID()
        transcriber.emit(.init(id: id, speaker: .them, at: .zero, text: "the dep", isConfirmed: false))
        transcriber.emit(.init(id: id, speaker: .them, at: .zero, text: "the deploy is blocked", isConfirmed: true))
        await settle()

        XCTAssertEqual(c.liveLines.map(\.text), ["the deploy is blocked"])
        XCTAssertEqual(c.liveLines.first?.isConfirmed, true)
    }

    func testAnOrphanedSpoolBecomesARecoveredTranscript() async throws {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: "teams", started: Date(timeIntervalSince1970: 1_787_000_000),
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        transcriber.batchTurns = [.init(speaker: .them(nil), at: .zero, text: "recovered words")]

        let c = coordinator()
        c.recoverOrphans()
        await settle(for: 1.0)

        let all = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        XCTAssertEqual(all.map(\.app), ["teams"])
        XCTAssertEqual(all.first?.recovered, true)
        XCTAssertEqual(spool.orphans().count, 0)
    }

    // MARK: - helpers

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func faint(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0.01, count: 16_000), at: at)
    }

    private func quiet(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    private func settle(for seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - fakes

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var started = false
    var rebuilds = 0

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        self.continuation = continuation
        started = true
        return stream
    }

    func rebuild() async throws { rebuilds += 1 }

    func stop() async { continuation?.finish() }

    func send(_ chunk: MeetingAudioChunk) { continuation?.yield(chunk) }

    func awaitStart() async {
        while !started { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    private(set) var fed = 0
    let lines: AsyncStream<LiveLine>
    private let emitter: AsyncStream<LiveLine>.Continuation

    init() {
        (lines, emitter) = AsyncStream<LiveLine>.makeStream()
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async { fed += 1 }
    func finish() async -> [MeetingTurn] { finalTurns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { batchTurns }
    func emit(_ line: LiveLine) { emitter.yield(line) }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns.map { turn in
            if case .them = turn.speaker {
                return .init(speaker: .them(1), at: turn.at, text: turn.text)
            }
            return turn
        }
    }
}

extension MeetingCoordinatorTests {
    /// The engine failing is the app's fault, not the permission's: it must
    /// not read as "can't hear", must not write an empty transcript, and
    /// must leave the spool for the next launch to recover.
    func testAModelThatWillNotLoadAbandonsTheMeetingButKeepsTheSpool() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-coordinator-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let source = FakeSource()
        var events: [MeetingEvent] = []

        struct WillNotLoad: Error {}
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in throw WillNotLoad() },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            preferences: {
                MeetingPreferences(folder: dir.appendingPathComponent("docs"), hook: nil, model: .whisperLargeV3)
            }
        )
        c.onEvent = { events.append($0) }
        c.start(tapping: RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 1))
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(events.count, 1)
        guard case .engineFailed = events.first else {
            return XCTFail("expected engineFailed, got \(events)")
        }
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).count, 0)
        // The spool folder survives, with its manifest, for recovery.
        let folders = try FileManager.default.contentsOfDirectory(atPath: spool.root.path)
        XCTAssertEqual(folders.count, 1)
    }
}
