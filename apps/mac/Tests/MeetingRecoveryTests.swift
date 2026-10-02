import XCTest

/// Recovery, through the coordinator and its fakes: a crash costs time and
/// never the meeting. A spool the app cannot read, or cannot read a model
/// for, is kept and says so; and what was set aside can be tried again.
@MainActor
final class MeetingRecoveryTests: XCTestCase {
    private var dir: URL!
    private var transcribers: FakeTranscribers!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []

    /// 2026-08-23 06:13:20 UTC.
    private let started = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transcribers = FakeTranscribers()
        events = []
        records = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }

    private func coordinator() -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: FakeSource(),
            makeTranscriber: { [transcribers] model in try transcribers!.next(for: model) },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: nil, model: .whisperLargeV3Turbo,
                    keepAudio: .deleteAtOnce)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    // MARK: - audio it cannot read

    /// A meeting the app cannot make sense of is still the only copy of it.
    /// It is kept where settings says it is, and the record says so — and no
    /// model is loaded for audio that will not read.
    func testAudioThatCannotBeReadIsSetAsideAndTheRecordSaysSo() async throws {
        let handle = try await orphan("teams", started: started)
        try Data("not audio".utf8).write(to: handle.audioURL)
        let c = coordinator()

        c.recoverOrphans()
        await awaitRecords(1)

        XCTAssertEqual(records.map(\.outcome), [.setAsideUnreadable])
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.recovered)
        XCTAssertEqual(record.app, "teams")
        XCTAssertEqual(record.startedAt, started)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(
            try Data(contentsOf: setAsideFolder(of: handle).appendingPathComponent("audio.caf")),
            Data("not audio".utf8))
        XCTAssertEqual(transcribers.made, [])
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 0)
    }

    // MARK: - helpers

    /// A spool a crash left behind, with a second of audio on it.
    @discardableResult
    private func orphan(
        _ app: String, started: Date, model: MeetingModel = .whisperLargeV3Turbo
    ) async throws -> MeetingSpool.Handle {
        let handle = try spool.begin(.init(
            app: app, started: started, engine: model.rawValue, model: model))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
        return handle
    }

    private func setAsideFolder(of handle: MeetingSpool.Handle) -> URL {
        spool.unreadableFolder.appendingPathComponent(handle.folder.lastPathComponent)
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// Until `count` records have arrived, or two seconds, so an ending that
    /// never leaves one fails the test instead of hanging it.
    private func awaitRecords(_ count: Int) async {
        for _ in 0..<200 where records.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

/// The tap. Recovery never opens it.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        AsyncStream<MeetingAudioChunk>.makeStream().stream
    }

    func rebuild() async throws {}
    func stop() async {}
}

private struct Unreadable: Error {}

/// One per reading, the way the app builds them, for the models that are on
/// this mac: asking for one that is not throws what the app's own does.
private final class FakeTranscribers: @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = Set(MeetingModel.allCases)
    private var _made: [MeetingModel] = []
    /// the one every transcriber made is.
    let transcriber = FakeTranscriber()

    /// The models that are on this mac, from now on.
    var installed: Set<MeetingModel> {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }

    /// The model each transcriber that was made was made for, in order.
    var made: [MeetingModel] {
        lock.withLock { _made }
    }

    func next(for model: MeetingModel) throws -> FakeTranscriber {
        try lock.withLock {
            guard _installed.contains(model) else {
                throw MeetingModel.NotInstalled(model: model)
            }
            _made.append(model)
            return transcriber
        }
    }
}

/// While `holds` is set, `transcribe` waits for the test to `release()` it —
/// a recovery still running.
private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var batchTurns: [MeetingTurn] = []
    /// what a spool the engine cannot read does at every launch.
    var batchFailure: (any Error)?
    /// what it says its decoding came to. nil keeps no count.
    var tally: StretchTally?
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var _holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {
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
    func finish() async -> [MeetingTurn] { [] }
    func decodeTally() async -> StretchTally? { tally }
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
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
