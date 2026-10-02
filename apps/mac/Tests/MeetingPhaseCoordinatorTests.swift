import Combine
import XCTest

/// The phase the coordinator publishes, which the menu, the badge and the
/// lamp all read: through the coordinator and fakes of its own, judged by
/// the phase, the events and whether the file is on disk.
@MainActor
final class MeetingPhaseCoordinatorTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: GatedTranscriber!
    private var disk: FreeSpace!
    private var events: [MeetingEvent] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-phase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = GatedTranscriber()
        disk = FreeSpace()
        events = []
    }

    override func tearDown() async throws {
        transcriber.loads()
        transcriber.finishes()
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }

    private func coordinator() -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(600),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
                diskLookedAtEvery: .seconds(1)),
            freeSpace: { [disk] _ in disk!.bytes },
            preferences: { [unowned self] in
                MeetingPreferences(folder: docs, hook: nil, model: .parakeetV3)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    // MARK: - the phase

    /// The tap hears its start sound in a moment; whisper takes ten-odd
    /// seconds to load. Until both are in, the meeting is getting ready.
    func testGettingReadyLastsWhileTheModelLoadsEvenOnceTheTapIsHeard() async throws {
        transcriber.loadsSlowly()
        let c = coordinator()

        c.start()
        XCTAssertEqual(c.phase, .gettingReady)
        await source.awaitStart()
        source.send(loud(at: .zero))
        await waitFor { c.state == .recording }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(c.phase, .gettingReady)

        transcriber.loads()
        await waitFor { c.phase == .recording }
        XCTAssertEqual(c.phase, .recording)
    }

    /// A problem is the phase for as long as it stands, and the meeting is
    /// recording again the moment it clears.
    func testAProblemIsThePhaseWhileItStands() async throws {
        disk.bytes = 0
        let c = coordinator()

        c.start()
        await source.awaitStart()
        source.send(loud(at: .zero))
        await waitFor { c.phase == .problem(.diskNearlyFull) }
        XCTAssertEqual(c.phase, .problem(.diskNearlyFull))

        disk.bytes = 50_000_000_000
        source.send(loud(at: .seconds(1)))
        source.send(loud(at: .seconds(2)))
        await waitFor { c.phase == .recording }
        XCTAssertEqual(c.phase, .recording)
    }

    /// From the stop until the file is on disk the meeting is being written
    /// out, and idle once it is.
    func testAStoppedMeetingIsWritingOutUntilItsFileIsOnDisk() async throws {
        transcriber.finishesSlowly()
        let c = coordinator()
        c.start()
        await source.awaitStart()
        source.send(loud(at: .zero))
        await waitFor { c.phase == .recording }

        c.stop()
        XCTAssertEqual(c.phase, .writingOut(recovering: nil))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.phase, .writingOut(recovering: nil))
        XCTAssertTrue(MeetingTranscriptFile.listAll(in: docs).isEmpty)

        transcriber.finishes()
        await c.untilWrittenOut()

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        XCTAssertEqual(c.phase, .idle)
    }

    /// What the menu, the badge and the lamp see, in order: never idle for
    /// a moment between the stop and writing it out, which would cool the
    /// lamp and bare the badge in the middle of a meeting's end.
    func testTheMeetingGoesThroughItsPhasesInOrder() async throws {
        transcriber.loadsSlowly()
        let c = coordinator()
        var seen: [MeetingPhase] = []
        let watching = c.$phase.removeDuplicates().sink { seen.append($0) }
        defer { watching.cancel() }

        c.start()
        await source.awaitStart()
        source.send(loud(at: .zero))
        await waitFor { c.state == .recording }
        transcriber.loads()
        await waitFor { c.phase == .recording }
        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(seen, [
            .idle, .gettingReady, .recording, .writingOut(recovering: nil), .idle,
        ])
    }

    /// Stopped before the tap was heard, there is nothing to write: only a
    /// spool to let go, which is never called writing it out.
    func testAStopBeforeTheTapIsHeardIsNeverWritingOut() async throws {
        let c = coordinator()
        var seen: [MeetingPhase] = []
        let watching = c.$phase.removeDuplicates().sink { seen.append($0) }
        defer { watching.cancel() }

        c.start()
        await source.awaitStart()
        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(seen, [.idle, .gettingReady, .idle])
        XCTAssertEqual(events, [.nothingToKeep])
    }

    /// A start that cannot hear ends as it always has: the pill says why,
    /// and the meeting goes straight back to idle.
    func testAStartThatCannotHearGoesStraightBackToIdle() async throws {
        let c = coordinator()
        var seen: [MeetingPhase] = []
        let watching = c.$phase.removeDuplicates().sink { seen.append($0) }
        defer { watching.cancel() }

        c.start()
        await source.awaitStart()
        source.send(quiet(at: .zero))
        source.send(quiet(at: .seconds(2)))
        await waitFor { c.state == .idle }
        await c.untilWrittenOut()

        XCTAssertEqual(seen, [.idle, .gettingReady, .idle])
        XCTAssertEqual(events, [.cannotHear])
    }

    // MARK: - helpers

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func quiet(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0, count: n), them: Array(repeating: 0, count: n), at: at)
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - fakes

/// The bytes free on the spool's disk, moved by the test.
private final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int64 = 50_000_000_000

    var bytes: Int64 {
        get { lock.withLock { free } }
        set { lock.withLock { free = newValue } }
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

/// A model that loads, and a reading that finishes, when the test lets it:
/// at once unless it was told to be slow.
private final class GatedTranscriber: MeetingTranscriber, @unchecked Sendable {
    let lines: AsyncStream<LiveLine>
    private let lock = NSLock()
    private var loaded = true
    private var finished = true

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    func loadsSlowly() { lock.withLock { loaded = false } }
    func loads() { lock.withLock { loaded = true } }
    func finishesSlowly() { lock.withLock { finished = false } }
    func finishes() { lock.withLock { finished = true } }

    func begin() async throws {
        while !lock.withLock({ loaded }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func feed(_ chunk: MeetingAudioChunk) async {}

    func finish() async -> [MeetingTurn] {
        while !lock.withLock({ finished }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return [.init(speaker: .you, at: .seconds(1), text: "the deploy is blocked")]
    }

    func decodeTally() async -> StretchTally? {
        StretchTally(decodedYou: 1, speechYou: .seconds(1), readYou: .seconds(1))
    }

    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
