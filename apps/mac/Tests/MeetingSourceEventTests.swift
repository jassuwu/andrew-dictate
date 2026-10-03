import XCTest

/// what the capture layer does by itself while a meeting runs — the mic it
/// moved to, a move that failed, the built-in mic it fell back on — lands in
/// the meeting's record as a label, at the meeting time it happened.
@MainActor
final class MeetingSourceEventTests: XCTestCase {
    private var dir: URL!
    private var source: TellingSource!
    private var transcriber: QuietTranscriber!
    private var hearing: VoiceHearing!
    private var records: [MeetingRecord] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-source-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = TellingSource()
        transcriber = QuietTranscriber()
        hearing = VoiceHearing()
        records = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func coordinator() -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: VoiceDiarizer(ear: hearing),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(60),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: dir.appendingPathComponent("docs"), hook: nil,
                    model: .whisperLargeV3Turbo)
            }
        )
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    /// airpods connect seven seconds in, a usb mic that will not start is
    /// picked at twelve, the airpods die at fifteen with nothing else to
    /// go to: three labels, each at the meeting time the source stamped it.
    func testWhatTheSourceDidIsInTheRecordAtTheTimeItHappened() async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<20 {
            source.send(loud(at: .seconds(s)))
        }
        source.tell(.init(kind: .micChanged, mic: "AirPods Pro", at: .seconds(7)))
        source.tell(.init(kind: .micHandoffFailed, mic: "Yeti", at: .milliseconds(12_300)))
        source.tell(.init(kind: .micFellBack, mic: "MacBook Pro Microphone", at: .seconds(15)))
        try? await Task.sleep(for: .milliseconds(300))

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "mic-changed"), atS: 7),
            .init(.init(rawValue: "mic-handoff-failed"), atS: 12.3),
            .init(.init(rawValue: "mic-fell-back"), atS: 15),
        ])
    }

    // MARK: - a time nothing was delivered

    /// The airpods died ten seconds in, and the built-in mic took over four
    /// seconds later: nothing came from either side between, and the source
    /// skipped its clock over it and said so. The file has that gap, the
    /// record the label, and a turn said after it is looked up on the spool
    /// where its audio is — a voice there, not one four seconds on.
    func testATimeTheSourceSaysNothingCameIsAGapAndTheTurnsAfterItAreWhereTheirAudioIs() async throws {
        // by where they are on the spool: the far side heard before the
        // outage, then two voices after it.
        hearing.speak([(from: .zero, number: 7), (from: .seconds(10), number: 3), (from: .seconds(15), number: 5)])
        transcriber.finalTurns = [
            them("before it", at: 2),
            them("just after it", at: 15),
            them("later on", at: 21),
        ]
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<10 {
            source.send(loud(at: .seconds(s)))
        }
        await until { c.elapsed >= .seconds(10) }
        source.tell(.init(kind: .nothingDelivered(until: .seconds(14)), mic: "MacBook Pro Microphone", at: .seconds(10)))
        for s in 14..<24 {
            source.send(loud(at: .seconds(s)))
        }
        await hearing.heard(20)

        c.stop()
        await c.untilWrittenOut()

        let saved = try savedFile()
        XCTAssertFalse(saved.complete)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [10.0, 14.0]"), body)
        XCTAssertEqual(records.first?.gaps, 1)
        XCTAssertEqual(records.first?.gapsLostS, 4)
        XCTAssertEqual(records.first?.events, [.init(.init(rawValue: "nothing-delivered"), atS: 10)])
        XCTAssertEqual(try lines(), [
            "[00:00:02] them 1: before it",
            "[00:00:15] them 2: just after it",
            "[00:00:21] them 3: later on",
        ])
    }

    /// The lid shut half a minute in and opened twenty minutes later, and
    /// the tap called back before the wake was heard: no chunk is late by
    /// the time anything asks. The source saw the wall jump between two
    /// buffers and said so — heard here after the chunks that followed —
    /// and that is a twenty-minute gap in the file, with the turn after it
    /// where its audio is.
    func testTwentyMinutesTheSourceSaysNothingCameIsATwentyMinuteGap() async throws {
        hearing.speak([(from: .zero, number: 7), (from: .seconds(30), number: 3), (from: .seconds(31), number: 5)])
        transcriber.finalTurns = [them("before the lid", at: 10), them("after the lid", at: 1_230.5)]
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<30 {
            source.send(loud(at: .seconds(s)))
        }
        source.send(loud(at: .seconds(1_230)))
        source.send(loud(at: .seconds(1_231)))
        await until { c.elapsed >= .seconds(1_232) }
        source.tell(.init(kind: .nothingDelivered(until: .seconds(1_230)), mic: "MacBook Pro Microphone", at: .seconds(30)))
        c.probeTapIsAlive()
        await hearing.heard(32)

        c.stop()
        await c.untilWrittenOut()

        let saved = try savedFile()
        XCTAssertEqual(saved.gapCount, 1)
        XCTAssertEqual(saved.duration, .seconds(1_232))
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("- [30.0, 1230.0]"), body)
        XCTAssertEqual(records.first?.gapsLostS, 1_200)
        XCTAssertEqual(try lines(), [
            "[00:00:10] them 1: before the lid",
            "[00:20:30] them 2: after the lid",
        ])
    }

    // MARK: -

    private func savedFile() throws -> MeetingSummary {
        try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first)
    }

    /// The body of the one transcript written: its paragraphs.
    private func lines() throws -> [String] {
        let body = try String(contentsOf: try savedFile().fileURL, encoding: .utf8)
        return body.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    private func them(_ text: String, at: Double) -> MeetingTurn {
        MeetingTurn(speaker: .them(nil), at: .seconds(at), text: text)
    }

    /// Until `done`, or two seconds.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }
}

// MARK: - fakes

/// A tap that can say what it did by itself: one stream of chunks and one
/// of events per start, both finished by its stop.
private final class TellingSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: AsyncStream<MeetingAudioChunk>.Continuation?
    private var told: AsyncStream<MeetingSourceEvent>.Continuation?
    private var events = AsyncStream<MeetingSourceEvent> { $0.finish() }
    private var starts = 0

    var sourceEvents: AsyncStream<MeetingSourceEvent> {
        lock.withLock { events }
    }

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, chunks) = AsyncStream<MeetingAudioChunk>.makeStream()
        let (events, told) = AsyncStream<MeetingSourceEvent>.makeStream()
        lock.withLock {
            self.chunks = chunks
            self.told = told
            self.events = events
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        let (chunks, told) = lock.withLock {
            defer {
                self.chunks = nil
                self.told = nil
            }
            return (self.chunks, self.told)
        }
        chunks?.finish()
        told?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { chunks }?.yield(chunk)
    }

    func tell(_ event: MeetingSourceEvent) {
        _ = lock.withLock { told }?.yield(event)
    }

    /// Until the tap has been opened, or two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Hears nothing, and finishes with the turns it is given.
private final class QuietTranscriber: MeetingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _finalTurns: [MeetingTurn] = []
    let lines = AsyncStream<LiveLine> { $0.finish() }

    var finalTurns: [MeetingTurn] {
        get { lock.withLock { _finalTurns } }
        set { lock.withLock { _finalTurns = newValue } }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

/// A diarizer that hears in pieces of a second, through one hearing the
/// test can look into.
private struct VoiceDiarizer: MeetingDiarizer {
    let ear: VoiceHearing

    func hearing() -> (any SpeakerHearing)? {
        ear
    }

    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns
    }
}

/// Numbers a turn by the voice speaking where it is on the spool: the
/// clock the split hears.
private final class VoiceHearing: SpeakerHearing, @unchecked Sendable {
    let pieceLength = 16_000
    private let lock = NSLock()
    private var pieces = 0
    private var voices: [(from: Duration, number: Int)] = []

    func speak(_ voices: [(from: Duration, number: Int)]) {
        lock.withLock { self.voices = voices }
    }

    func hear(_ piece: [Float], at: Duration) async throws {
        lock.withLock { pieces += 1 }
    }

    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn] {
        let voices = lock.withLock { self.voices }
        return turns.map { turn in
            guard case .them = turn.speaker,
                  let voice = voices.last(where: { $0.from <= turn.at })
            else { return turn }
            return turn.said(by: .them(voice.number))
        }
    }

    /// Until `count` pieces have been handed over, or two seconds.
    func heard(_ count: Int) async {
        for _ in 0..<200 {
            if lock.withLock({ pieces >= count }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
