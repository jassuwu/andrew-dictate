import XCTest

/// `record with`: one meeting heard by a model other than the one in
/// settings. Through the coordinator and its fakes, judged by what the
/// engine was asked for and by what the spool and the file say afterwards.
@MainActor
final class MeetingStartModelTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var asked: ModelsAsked!
    /// What settings say right now: the default, unless a test moves it.
    private var defaultModel: MeetingModel = .whisperLargeV3

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-start-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        asked = ModelsAsked()
        defaultModel = .whisperLargeV3
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }

    /// Each meeting starts an hour after the one before, so each is its own
    /// file.
    private func coordinator() -> MeetingCoordinator {
        let dates = StartDates([
            Date(timeIntervalSince1970: 1_790_923_951),
            Date(timeIntervalSince1970: 1_790_927_551),
        ])
        return MeetingCoordinator(
            source: source,
            makeTranscriber: { [asked] model in
                asked!.record(model)
                return FakeTranscriber()
            },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600)),
            date: { dates.next() },
            preferences: { [unowned self] in
                MeetingPreferences(folder: docs, hook: nil, model: defaultModel)
            }
        )
    }

    // MARK: -

    /// The model goes to the engine, into the spool's manifest (so a crash
    /// is recovered by the model that heard it) and into the file's front
    /// matter, and settings are not touched.
    func testAMeetingStartedWithAnotherModelIsHeardByIt() async throws {
        let c = coordinator()

        c.start(model: .parakeetV3)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await waitFor { c.state == .recording }

        XCTAssertEqual(asked.models, [.parakeetV3])
        let manifest = try XCTUnwrap(spool.orphans().first?.manifest)
        XCTAssertEqual(manifest.model, .parakeetV3)
        XCTAssertEqual(manifest.engine, "parakeetV3")

        c.stop()
        await c.untilWrittenOut()

        let saved = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        let body = try String(contentsOf: saved.fileURL, encoding: .utf8)
        XCTAssertTrue(body.contains("engine: parakeetV3\n"), body)
        XCTAssertEqual(defaultModel, .whisperLargeV3)
    }

    // MARK: - helpers

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

/// The models the engine was asked for, in order: one per meeting.
private final class ModelsAsked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [MeetingModel] = []

    var models: [MeetingModel] {
        lock.withLock { asked }
    }

    func record(_ model: MeetingModel) {
        lock.withLock { asked.append(model) }
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

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var startsSeen = 0

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { continuation = nil }
            return continuation
        }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { continuation }?.yield(chunk)
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

/// Hears a meeting say one thing and the coverage check has nothing to
/// quarrel with.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    let lines: AsyncStream<LiveLine>

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] {
        [.init(speaker: .you, at: .seconds(1), text: "the deploy is blocked")]
    }
    func decodeTally() async -> StretchTally? {
        StretchTally(decodedYou: 1, speechYou: .seconds(1), readYou: .seconds(1))
    }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
