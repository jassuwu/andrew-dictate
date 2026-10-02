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
            makeTranscriber: { [transcribers] _ in try transcribers!.next() },
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

    /// a tap that will not open at all is the same news as one that never
    /// heard the start sound, and is told the same way.
    func testATapThatCouldNotBeOpenedLeavesARecordSayingItWasNeverHeard() async throws {
        source.opening = Unreadable()
        let c = coordinator(starting: [started])

        c.start(tapping: zoom)
        await awaitRecords(1)
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .nothingKept(.tapNeverHeard))
        XCTAssertEqual(records.first?.durationS, 0)
        XCTAssertEqual(c.state, .idle)
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

    // MARK: - the decoding

    /// the engine's own count of its work: how many stretches it read per
    /// side, how many it gave up on, and how far behind the meeting it ran.
    func testTheRecordHasTheDecodeNumbersOfAnEngineThatKeepsThem() async throws {
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "hello")]
        transcriber.tally = StretchTally(
            decodedYou: 7, decodedThem: 12, failed: 1,
            mostBehind: .seconds(9.5), lastBehind: .seconds(2.5))
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decoding, .init(
            decodedYou: 7, decodedThem: 12, failed: 1, mostBehindS: 9.5, lastBehindS: 2.5))
    }

    /// an engine that keeps no count says nothing, and the record does not
    /// make one up.
    func testAnEngineThatKeepsNoCountLeavesNoDecodeNumbers() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.decoding)
    }

    /// a recovery decodes too, and a spool is decoded the same way a
    /// meeting is.
    func testARecoveryHasTheDecodeNumbersToo() async throws {
        try await orphan("teams", started: started)
        transcriber.tally = StretchTally(decodedYou: 3, decodedThem: 4)
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.first?.decoding, .init(
            decodedYou: 3, decodedThem: 4, failed: 0, mostBehindS: 0, lastBehindS: 0))
    }

    /// the stretch transcriber is the one that keeps a count, and says so
    /// through the protocol the coordinator holds it by.
    func testTheStretchTranscriberReportsItsTallyThroughTheProtocol() async throws {
        let engine = SilentEngine()
        let transcriber: any MeetingTranscriber = StretchTranscriber(
            engine: engine, ceiling: .seconds(15))

        let tally = await transcriber.decodeTally()

        XCTAssertEqual(tally, StretchTally())
    }

    // MARK: - what happened on the way

    /// the mac sleeps through most of an hour and wakes: the record says
    /// when the tap was lost and when it was heard again, by the meeting's
    /// clock.
    func testTheRecordKeepsWhenTheTapWasLostAndHeardAgain() async throws {
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1_082)))
        await settle()
        clock.advance(by: .seconds(3_498))
        c.probeTapIsAlive()
        await settle()
        source.send(loud(at: .seconds(3_498)))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 1_083),
            .init(.gapEnded, atS: 3_499),
        ])
    }

    /// the other way a tap is lost: it keeps calling back, with nothing but
    /// zeros in it, for longer than a quiet room would.
    func testTheRecordKeepsATapThatKeptCallingBackWithSilence() async throws {
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()
        source.send(quiet(at: .seconds(1)))
        await settle()
        // seven seconds in, and six since anything was heard.
        source.send(quiet(at: .seconds(6)))
        await settle()
        source.send(loud(at: .seconds(7)))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.gapBegan, atS: 7),
            .init(.gapEnded, atS: 8),
        ])
    }

    /// a tap that cannot be rebuilt ends the meeting with most of it on the
    /// spool: the record has the gap that never closed, and the failure.
    func testTheRecordKeepsATapThatCouldNotBeRebuilt() async throws {
        source.rebuilding = Unreadable()
        let clock = FakeClock()
        let c = coordinator(clock: clock)
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1_082)))
        await settle()

        clock.advance(by: .seconds(3_498))
        c.probeTapIsAlive()
        await awaitRecords(1)
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .saved)
        XCTAssertEqual(record.events, [
            .init(.gapBegan, atS: 1_083),
            .init(.rebuildFailed, atS: 3_498),
        ])
        XCTAssertEqual(record.gaps, 1)
        XCTAssertEqual(record.gapsLostS, 2_415)
    }

    // MARK: - recovery

    /// a spool the app died on, written out at the next launch: the same
    /// record as any saved meeting, from the manifest and the audio, and
    /// marked as the recovery it was.
    func testARecoveredMeetingLeavesARecordMarkedRecovered() async throws {
        try await orphan("teams", started: started)
        transcriber.batchTurns = [
            .init(speaker: .them(nil), at: .zero, text: "recovered words here")]
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .saved)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.app, "teams")
        XCTAssertEqual(record.model, "whisperLargeV3Turbo")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 1)
        XCTAssertEqual(record.you, .init(turns: 0, words: 0))
        XCTAssertEqual(record.them, .init(turns: 1, words: 3))
        // a recovery has no stop of its own to count from.
        XCTAssertNil(record.toDiskS)
        // and a meeting that was not one says so.
        XCTAssertFalse(MeetingRecord(
            .saved, app: "zoom", model: .whisperLargeV3, startedAt: started, duration: .zero
        ).recovered)
    }

    /// two tries, then the spool is set aside: each failure is its own
    /// record, so a spool that will not read shows as two before it stops.
    func testARecoveryThatFailsIsCountedAndTheSecondFailureSetsTheSpoolAside() async throws {
        try await orphan("teams", started: started)
        transcriber.batchFailure = Unreadable()
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)
        XCTAssertEqual(records.map(\.outcome), [.couldNotRecover])
        XCTAssertEqual(spool.orphans().count, 1, "one failure is not two")

        c.recoverOrphans()
        await awaitRecords(2)

        XCTAssertEqual(records.map(\.outcome), [.couldNotRecover, .setAside])
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(records.map(\.recovered), [true, true])
        XCTAssertEqual(records.map(\.app), ["teams", "teams"])
        XCTAssertEqual(records.map(\.startedAt), [started, started])
    }

    /// audio the app cannot read at all: there is nothing to try, and the
    /// record is the only thing that says the meeting is gone.
    func testASpoolThatCannotBeReadLeavesARecordSayingSo() async throws {
        let handle = try await orphan("teams", started: started)
        try Data("not audio".utf8).write(to: handle.audioURL)
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .spoolUnreadable)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.app, "teams")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 0)
    }

    // MARK: - the file

    /// the transcript could not be written where it was asked to go: the
    /// audio stays, the next launch tries again, and the record says it was
    /// the file that failed — with what was heard, since that was not lost.
    func testATranscriptThatCouldNotBeWrittenLeavesARecordAndKeepsTheSpool() async throws {
        // a file where the meetings folder should be: nothing can be made in it.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: dir.appendingPathComponent("docs").path, contents: Data()))
        transcriber.finalTurns = [
            .init(speaker: .you, at: .seconds(1), text: "hello there"),
            .init(speaker: .them(nil), at: .seconds(2), text: "hi"),
        ]
        let c = coordinator()
        c.start(tapping: zoom)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .couldNotWrite)
        XCTAssertEqual(record.durationS, 2)
        XCTAssertEqual(record.you, .init(turns: 1, words: 2))
        XCTAssertEqual(record.them, .init(turns: 1, words: 1))
        XCTAssertNil(record.toDiskS)
        XCTAssertEqual(try spoolFolders(), 1)
    }

    // MARK: - the model

    /// the engine failing is the app's fault: the recording stops, the audio
    /// stays for the next launch, and the record says the model was why.
    func testAModelThatCouldNotBeMadeLeavesARecordAndKeepsTheSpool() async throws {
        transcribers.failure = Unreadable()
        let c = coordinator(starting: [started])

        c.start(tapping: zoom)
        await awaitRecords(1)
        await settle()

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .modelFailed)
        XCTAssertEqual(record.app, "zoom")
        XCTAssertEqual(record.model, "whisperLargeV3Turbo")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(record.durationS, 0)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(try spoolFolders(), 1)
    }

    func testAModelThatWillNotLoadLeavesARecordAndKeepsTheSpool() async throws {
        transcriber.beginFailure = Unreadable()
        let c = coordinator()

        c.start(tapping: zoom)
        await awaitRecords(1)
        await settle()

        XCTAssertEqual(records.map(\.outcome), [.modelFailed])
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(try spoolFolders(), 1)
    }

    // MARK: - helpers

    /// A spool a crash left behind, with a second of audio on it.
    @discardableResult
    private func orphan(_ app: String, started: Date) async throws -> MeetingSpool.Handle {
        let spool = MeetingSpool(root: dir.appendingPathComponent("spool"))
        let handle = try spool.begin(.init(
            app: app, started: started,
            engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        return handle
    }

    private func spoolFolders() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("spool").path
        ).filter { !$0.hasPrefix(".") }.count
    }

    /// Until `count` records have arrived, or two seconds, so an ending that
    /// never leaves one fails the test instead of hanging it.
    private func awaitRecords(_ count: Int) async {
        for _ in 0..<200 where records.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

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
    /// what rebuilding the tap does, while it is set: the device is gone.
    var rebuilding: (any Error)?
    /// what opening the tap does, while it is set: the permission is off.
    var opening: (any Error)?

    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation? {
        lock.withLock { _continuation }
    }

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        if let opening { throw opening }
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            _continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {
        rebuilds += 1
        if let rebuilding { throw rebuilding }
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

private struct SilentEngine: StretchEngine {
    func load() async throws {}
    func text(of samples: [Float]) async throws -> String { "" }
}

/// One per meeting, the way the app builds them. The test lines up the ones
/// it wants to hold or read; a meeting past those gets the shared one.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var lined: [FakeTranscriber] = []
    private let otherwise: FakeTranscriber
    /// what making the next transcriber does, while it is set: a model that
    /// is not on this mac, or will not load.
    var failure: (any Error)?

    init(otherwise: FakeTranscriber) {
        self.otherwise = otherwise
    }

    func lineUp(_ transcribers: FakeTranscriber...) {
        lock.withLock { lined.append(contentsOf: transcribers) }
    }

    func next() throws -> FakeTranscriber {
        if let failure { throw failure }
        return lock.withLock { lined.isEmpty ? otherwise : lined.removeFirst() }
    }
}

/// While `holds` is set, `finish` and `transcribe` wait for the test to
/// `release()` them — the last decode of a meeting, or the whole of a
/// recovery's, still running.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    /// what an engine that keeps count says about its decoding.
    var tally: StretchTally?
    /// what a spool the engine cannot read does at every launch.
    var batchFailure: (any Error)?
    /// what loading the model does, while it is set.
    var beginFailure: (any Error)?
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

    func begin() async throws {
        if let beginFailure { throw beginFailure }
    }
    func feed(_ chunk: MeetingAudioChunk) async {}
    func decodeTally() async -> StretchTally? { tally }
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
