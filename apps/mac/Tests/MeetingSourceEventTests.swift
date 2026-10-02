import XCTest

/// what the capture layer does by itself while a meeting runs — the mic it
/// moved to, a move that failed, the built-in mic it fell back on — lands in
/// the meeting's record as a label, at the meeting time it happened.
@MainActor
final class MeetingSourceEventTests: XCTestCase {
    private var dir: URL!
    private var source: TellingSource!
    private var records: [MeetingRecord] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-source-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = TellingSource()
        records = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func coordinator() -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { _ in QuietTranscriber() },
            diarizer: SameDiarizer(),
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

private struct QuietTranscriber: MeetingTranscriber {
    let lines = AsyncStream<LiveLine> { $0.finish() }
    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { [] }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct SameDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
