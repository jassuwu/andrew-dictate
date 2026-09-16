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
            silenceFloor: 0.001, quietNudgeAfter: .seconds(30)),
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let folder = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: thresholds,
            now: { clock.now },
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
        // the pill ignores the mouse, so it points at setup rather than at a
        // switch the user would then have to go and find.
        XCTAssertEqual(events.first?.hudText, "can't hear zoom — opening setup")
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

    func testFaintAudioCountsAsActivity() async throws {
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
        XCTAssertEqual(c.state, .recording)
    }

    /// SPEC §11's hour of silence. It could never arrive: every rebuild
    /// replays the start sound into our own tap, and every silent chunk in
    /// between read as activity, so the quiet clock was reset every two
    /// minutes for as long as the quiet lasted.
    func testASilentHourAsksOnce() async throws {
        let c = coordinator()
        // the real source chirps on every rebuild and the tap hears this
        // app: a fake that stays mute cannot see the bug.
        source.toneOnRebuild = loud(at: .zero)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        // nobody says another word. the tap goes silent, rebuilds, hears its
        // own tone, and goes silent again — over and over.
        await beQuiet(from: 5, through: 60)

        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "\(events)")
        XCTAssertTrue(events.contains(.gapBegan))
        XCTAssertGreaterThan(source.rebuilds, 1, "the tone really was replayed")
    }

    /// ADR 0023: it asks, it never acts — and an answered nudge does not come
    /// straight back.
    func testAnsweringTheNudgeBuysAnotherQuietSpan() async throws {
        let c = coordinator()
        source.toneOnRebuild = loud(at: .zero)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        await beQuiet(from: 5, through: 40)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "\(events)")

        c.keepGoing()
        await beQuiet(from: 45, through: 65)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 1, "answered, so it waits")

        await beQuiet(from: 70, through: 100)
        XCTAssertEqual(events.filter { $0 == .nudge }.count, 2, "\(events)")
    }

    /// SPEC §11: a tap that stops calling back — a sleep, a locked screen, a
    /// driver that died — is a gap like any other. No chunk ever arrives to
    /// report it, so nothing inside `ingest` can: only the wall clock knows,
    /// and a file that says `complete: true` over forty minutes it never
    /// heard is the one failure that looks exactly like a success.
    func testAMacThatSleptThroughAMeetingSaysSoInTheFile() async throws {
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1_082)))
        await settle()
        XCTAssertEqual(c.state, .recording)
        XCTAssertEqual(c.elapsed, .seconds(1_083))

        // the lid closes at 00:18:03; forty minutes later the mac wakes and
        // asks the tap whether it is still there.
        clock.advance(by: .seconds(2_415))
        c.probeTapIsAlive()
        await settle()

        XCTAssertEqual(c.state, .rebuilding)
        XCTAssertTrue(events.contains(.gapBegan), "\(events)")
        XCTAssertEqual(c.elapsed, .seconds(3_498), "the menu stops counting frozen frames")

        // the rebuilt tap hears the room again, wall-aligned.
        source.send(loud(at: .seconds(3_498)))
        await settle()
        XCTAssertTrue(events.contains(.gapEnded), "\(events)")

        clock.advance(by: .seconds(230))
        c.stop()
        await settle(for: 1.0)

        let saved = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
        XCTAssertFalse(saved.complete)
        XCTAssertEqual(saved.gapCount, 1)
        XCTAssertEqual(saved.duration, .seconds(3_728))
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [1083.0, 3499.0]"), body)
        XCTAssertTrue(body.contains("complete: false"), body)
    }

    /// The other half of the same rule: a wall clock that has moved is not
    /// on its own a reason to declare a gap.
    func testATapStillCallingBackIsNotDeclaredDead() async throws {
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        clock.advance(by: .seconds(2))
        c.probeTapIsAlive()
        await settle()

        XCTAssertEqual(c.state, .recording)
        XCTAssertFalse(events.contains(.gapBegan), "\(events)")
        XCTAssertEqual(source.rebuilds, 0)
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

    /// Silence, delivered the way a live tap delivers it: one chunk at a
    /// time, with room for a rebuild and its tone to land in between.
    private func beQuiet(from first: Int, through last: Int) async {
        for s in stride(from: first, through: last, by: 5) {
            source.send(quiet(at: .seconds(s)))
            await settle(for: 0.12)
        }
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - fakes

/// A wall the test moves by hand — the coordinator only ever reads it.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func advance(by amount: Duration) {
        lock.withLock { offset += amount }
    }
}

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var started = false
    private var nextAt: Duration = .zero
    var rebuilds = 0
    /// The real source plays the start sound again on every rebuild, and the
    /// tap is scoped to this app as well — so the tone comes back as far-side
    /// audio a moment later. A fake that stays mute cannot see what that
    /// does to the quiet clock.
    var toneOnRebuild: MeetingAudioChunk?

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        self.continuation = continuation
        started = true
        return stream
    }

    func rebuild() async throws {
        rebuilds += 1
        guard let tone = toneOnRebuild else { return }
        send(MeetingAudioChunk(you: tone.you, them: tone.them, at: nextAt))
    }

    func stop() async { continuation?.finish() }

    func send(_ chunk: MeetingAudioChunk) {
        nextAt = chunk.at + chunk.duration
        continuation?.yield(chunk)
    }

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
