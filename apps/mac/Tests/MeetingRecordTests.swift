import XCTest

/// the meeting record, through the coordinator and its fakes: whatever way a
/// meeting ends, it leaves exactly one, with the numbers of that meeting in
/// it and none of its words.
@MainActor
final class MeetingRecordTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var transcribers: FakeTranscribers!
    private var records: [MeetingRecord] = []
    private var meetingModel: MeetingModel = .whisperLargeV3Turbo

    private let zoom = RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 42)
    /// 2026-08-23 06:13:20 UTC.
    private let started = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        transcribers = FakeTranscribers(otherwise: transcriber)
        records = []
        meetingModel = .whisperLargeV3Turbo
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `starting` is the date each meeting starts on, in order; a meeting
    /// past the end of it starts now.
    private func coordinator(
        clock: FakeClock = FakeClock(),
        starting dates: [Date] = []
    ) -> MeetingCoordinator {
        let dates = StartDates(dates)
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcribers] _ in transcribers!.next() },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(30)),
            now: { clock.now },
            date: { dates.next() },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: dir.appendingPathComponent("docs"), hook: nil, model: meetingModel)
            }
        )
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - saved

    func testASavedMeetingLeavesOneRecord() async throws {
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "hello")]
        let c = coordinator(starting: [started])
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .saved)
        XCTAssertEqual(record.app, "zoom")
        XCTAssertEqual(record.model, "whisperLargeV3Turbo")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 2)
    }

    /// two sides, four turns, and a mac that slept through most of an hour:
    /// the record has the numbers the file has, and none of the talk.
    func testTheRecordCountsTheTurnsAndWordsOfEachSideAndTheGap() async throws {
        transcriber.finalTurns = [
            .init(speaker: .you, at: .seconds(1), text: "alpha beta gamma"),
            .init(speaker: .them(nil), at: .seconds(2), text: "delta epsilon"),
            .init(speaker: .them(nil), at: .seconds(3), text: "zeta"),
            .init(speaker: .you, at: .seconds(5), text: "eta theta"),
        ]
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1_082)))
        await settle()

        // the lid closes at 00:18:03 and the mac wakes at 00:58:18.
        clock.advance(by: .seconds(3_498))
        c.probeTapIsAlive()
        await settle()
        source.send(loud(at: .seconds(3_498)))
        await settle()
        clock.advance(by: .seconds(230))

        c.stop()
        await c.untilWrittenOut()

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.durationS, 3_728)
        XCTAssertEqual(record.gaps, 1)
        // the gap is [1083, 3499].
        XCTAssertEqual(record.gapsLostS, 2_416)
        XCTAssertEqual(record.you, .init(turns: 2, words: 5))
        XCTAssertEqual(record.them, .init(turns: 2, words: 3))
    }

    /// a long meeting's last decode is the wait that matters: how long the
    /// file took after the stop is the number a "where did my transcript
    /// go" is answered with.
    func testTheRecordSaysHowLongTheFileTookAfterTheStop() async throws {
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "hello")]
        transcriber.holds = true
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()

        c.stop()
        await held(transcriber)
        clock.advance(by: .seconds(42))
        transcriber.release()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.toDiskS, 42)
    }

    // MARK: - nothing kept

    /// the tap that never heard the start sound: the lamp said "can't hear"
    /// and nothing was kept, and the record says which of the two it was.
    func testATapThatWasNeverHeardLeavesARecordSayingSo() async throws {
        let c = coordinator(starting: [started])
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(quiet(at: .zero))
        source.send(quiet(at: .seconds(2)))
        await settle()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .nothingKept(.tapNeverHeard))
        XCTAssertEqual(record.app, "zoom")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 3)
        XCTAssertNil(record.toDiskS)
    }

    /// stopped while the start sound was still being waited for: nothing
    /// had been captured, and nothing is wrong with the tap that anyone knows.
    func testAMeetingStoppedBeforeAnythingWasCapturedLeavesARecordSayingSo() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(quiet(at: .zero))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .nothingKept(.stoppedBeforeCapture))
        XCTAssertEqual(records.first?.durationS, 1)
    }

    // MARK: - helpers

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func quiet(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    private func settle(for seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Until the transcriber is parked in its hold, or two seconds, so a
    /// test against code that never gets there fails instead of hanging.
    private func held(_ transcriber: FakeTranscriber) async {
        for _ in 0..<200 where !transcriber.isWaiting {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

/// The dates meetings start on, one each, in order.
private final class StartDates: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.withLock { dates.isEmpty ? Date() : dates.removeFirst() }
    }
}

/// The tap. Opened again after a stop, it starts a new stream, the way the
/// real one does for the next meeting.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0
    private var nextAt: Duration = .zero
    var rebuilds = 0

    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation? {
        lock.withLock { _continuation }
    }

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            _continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {
        rebuilds += 1
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { _continuation = nil }
            return _continuation
        }
        continuation?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        nextAt = chunk.at + chunk.duration
        continuation?.yield(chunk)
    }

    /// Until the tap has been opened once more than the last call saw, or
    /// two seconds — a meeting that never opens it fails the test instead
    /// of hanging it.
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

private struct Unreadable: Error {}

/// One per meeting, the way the app builds them. The test lines up the ones
/// it wants to hold or read; a meeting past those gets the shared one.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [FakeTranscriber] = []
    private let otherwise: FakeTranscriber

    init(otherwise: FakeTranscriber) {
        self.otherwise = otherwise
    }

    func lineUp(_ transcribers: FakeTranscriber...) {
        lock.withLock { lined.append(contentsOf: transcribers) }
    }

    func next() -> FakeTranscriber {
        lock.withLock { lined.isEmpty ? otherwise : lined.removeFirst() }
    }
}

/// While `holds` is set, `finish` and `transcribe` wait for the test to
/// `release()` them — the last decode of a meeting, or the whole of a
/// recovery's, still running.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    /// what a spool the engine cannot read does at every launch.
    var batchFailure: (any Error)?
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(finalTurns: [MeetingTurn] = [], batchTurns: [MeetingTurn] = []) {
        self.finalTurns = finalTurns
        self.batchTurns = batchTurns
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    var isWaiting: Bool {
        lock.withLock { !waiting.isEmpty }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] {
        await heldUntilReleased()
        return finalTurns
    }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] {
        await heldUntilReleased()
        if let batchFailure { throw batchFailure }
        return batchTurns
    }

    func release() {
        let released = lock.withLock {
            _holds = false
            let released = waiting
            waiting = []
            return released
        }
        for continuation in released {
            continuation.resume()
        }
    }

    private func heldUntilReleased() async {
        guard holds else { return }
        // the hold is checked again in the same lock that registers the
        // wait: a release landing between the two would otherwise leave
        // this waiting on a release that already happened.
        await withCheckedContinuation { continuation in
            let goNow = lock.withLock {
                guard _holds else {
                    return true
                }
                waiting.append(continuation)
                return false
            }
            if goNow {
                continuation.resume()
            }
        }
    }
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
