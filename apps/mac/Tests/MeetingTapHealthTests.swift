import XCTest

/// A meeting's tap, kept honest through the coordinator and its fakes:
/// silence is never damage, a quiet far side is asked about with a quiet
/// tone, a dead tap is rebuilt patiently, and one that cannot be rebuilt is
/// a problem the meeting records through rather than the end of it.
@MainActor
final class MeetingTapHealthTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-tap-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
        records = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The test's own numbers: a five-second timeout and a two-second
    /// window, in meeting time.
    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2)),
        clock: FakeClock = FakeClock()
    ) -> MeetingCoordinator {
        let docs = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: thresholds,
            now: { clock.now },
            preferences: {
                MeetingPreferences(folder: docs, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - silence is not damage

    /// Presenting to a room that has nothing playing: five minutes of
    /// nothing from the far side is a quiet room. No tone, no gap, no
    /// rebuild, and a file that says it is whole.
    func testFiveMinutesOfSilenceWithNothingPlayingIsLeftAlone() async throws {
        source.anythingIsPlaying = false
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))

        for s in stride(from: 10, through: 300, by: 10) {
            source.send(quiet(at: .seconds(s)))
        }
        await until { c.elapsed >= .seconds(300) }

        XCTAssertEqual(source.quietProbes, 0)
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.gapCount, 0)
        XCTAssertEqual(records.first?.events, [])
    }

    /// The call ended and the recording ran on: an hour with nothing
    /// playing. It used to chirp, rebuild and cut a gap every two minutes;
    /// now it asks nothing at all.
    func testAnHourOfSilenceAfterEverythingStoppedPlayingAsksNothing() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero), loud(at: .seconds(1)))

        source.anythingIsPlaying = false
        for s in stride(from: 10, through: 3_600, by: 10) {
            source.send(quiet(at: .seconds(s)))
        }
        await until { c.elapsed >= .seconds(3_600) }

        XCTAssertEqual(source.quietProbes, 0)
        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        XCTAssertEqual(records.first?.events, [])
    }

    // MARK: - the quiet probe

    /// You present for longer than the timeout while the call app plays
    /// a muted room. The tap is asked once, with the quiet tone, and hears
    /// it: nothing else happens, the lamp says nothing, and the next
    /// question waits a full timeout from the tone.
    func testAQuietProbeTheTapHearsChangesNothingAndTheNextWaitsAFullTimeout() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))

        for s in 2...5 {
            await play(quiet(at: .seconds(s)))
        }
        XCTAssertEqual(source.quietProbes, 0, "five seconds is not past the timeout")

        await play(quiet(at: .seconds(6)))
        await until { source.quietProbes == 1 }
        XCTAssertEqual(source.quietProbes, 1)

        // the tone comes back through the tap at 7.0–7.3.
        await play(tone(at: .seconds(7)))
        for s in 8...12 {
            await play(quiet(at: .seconds(s)))
        }
        XCTAssertEqual(source.quietProbes, 1, "not sooner than a full timeout after the tone")

        await play(quiet(at: .seconds(13)))
        await until { source.quietProbes == 2 }
        XCTAssertEqual(source.quietProbes, 2)

        XCTAssertEqual(source.rebuilds, 0)
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        XCTAssertTrue(try savedFile().complete)
        // the second question was still open at the stop.
        XCTAssertEqual(records.first?.events, [.init(.probeHeard, atS: 7.3)])
    }

    /// Asked, and the window passes with nothing: that is a dead tap. The
    /// gap begins where the question went unanswered, the tap is rebuilt,
    /// the rebuilt tap hears its start sound, and the gap ends there.
    func testAQuietProbeTheTapMissesIsAGapARebuildAndARecovery() async throws {
        source.anythingIsPlaying = true
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(loud(at: .zero))
        for s in 2...6 {
            await play(quiet(at: .seconds(s)))
        }
        await until { source.quietProbes == 1 }

        await play(quiet(at: .seconds(7)), quiet(at: .seconds(8)))
        XCTAssertEqual(source.rebuilds, 0, "the window is not over")
        await play(quiet(at: .seconds(9)))
        await until { events.contains(.gapEnded) }

        XCTAssertEqual(source.rebuilds, 1)
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])
        XCTAssertEqual(c.state, .recording)

        c.stop()
        await c.untilWrittenOut()
        let saved = try savedFile()
        XCTAssertFalse(saved.complete)
        XCTAssertEqual(saved.gapCount, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.probeUnheard, atS: 9.1),
            .init(.gapBegan, atS: 9.1),
            .init(.gapEnded, atS: 9.4),
        ])
    }

    // MARK: - helpers

    private func savedFile() throws -> MeetingSummary {
        try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
    }

    /// The far side talking, and you.
    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// A tenth of a second of nothing on either side. Short, so an hour of
    /// it is not an hour of spool.
    private func quiet(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 1_600),
              them: Array(repeating: 0, count: 1_600), at: at)
    }

    /// The quiet probe as the tap hears it: 0.3 s of a 1 kHz tone at
    /// -40 dBFS, RMS about 0.007.
    private func tone(at: Duration) -> MeetingAudioChunk {
        let n = 4_800
        return .init(you: Array(repeating: 0, count: n),
                     them: (0..<n).map { sin(Float($0) * 2 * .pi * 1_000 / 16_000) * 0.01 },
                     at: at)
    }

    /// Each chunk, and time for the coordinator to have taken it in before
    /// the next: a tone the source plays in answer lands in between.
    private func play(_ chunks: MeetingAudioChunk...) async {
        for chunk in chunks {
            source.send(chunk)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// Until `done`, or two seconds, so a test against code that never gets
    /// there fails instead of hanging.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
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

/// The tap, and the two tones it plays: the start sound on every start and
/// rebuild, and the quiet probe when asked.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0
    private var nextAt: Duration = .zero
    private var _rebuilds = 0
    private var _quietProbes = 0
    private var _anythingIsPlaying: Bool?

    var rebuilds: Int { lock.withLock { _rebuilds } }
    var quietProbes: Int { lock.withLock { _quietProbes } }

    var anythingIsPlaying: Bool? {
        get { lock.withLock { _anythingIsPlaying } }
        set { lock.withLock { _anythingIsPlaying = newValue } }
    }

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    /// A rebuilt tap plays the start sound, and hears it come back a moment
    /// later as far-side audio, the way the real one does.
    func rebuild() async throws {
        let at = lock.withLock { () -> Duration in
            _rebuilds += 1
            return nextAt
        }
        let n = 4_800
        send(.init(you: Array(repeating: 0, count: n),
                   them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at))
    }

    func playQuietProbe() async throws {
        lock.withLock { _quietProbes += 1 }
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            nextAt = chunk.at + chunk.duration
            return self.continuation
        }
        continuation?.yield(chunk)
    }

    /// Until the tap has been opened once more than the last call saw, or
    /// two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            let opened = lock.withLock {
                guard starts > startsSeen else { return false }
                startsSeen += 1
                return true
            }
            if opened { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Counts what it is fed; says nothing.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _fed: [MeetingAudioChunk] = []

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    var fed: [MeetingAudioChunk] {
        lock.withLock { _fed }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {
        lock.withLock { _fed.append(chunk) }
    }
    func finish() async -> [MeetingTurn] { [] }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
