import XCTest

/// A meeting that cannot hear you, or cannot save, says so while it can
/// still be fixed: through the coordinator and its fakes, the problems that
/// stand until they clear, and a start that fails saying which part did.
@MainActor
final class MeetingProblemsTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []
    private var records: [MeetingRecord] = []
    /// The coordinator `play` waits on.
    private weak var playing: MeetingCoordinator?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-problems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
        records = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The test's own numbers: a one-second start window, and the mic
    /// given ten seconds of silence, in meeting time.
    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(60),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2),
            settleBeforeRebuild: .milliseconds(50))
    ) -> MeetingCoordinator {
        let docs = dir.appendingPathComponent("docs")
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            keptAudio: KeptAudio(
                root: dir.appendingPathComponent("meeting-audio"),
                compress: { _, _ in throw CocoaError(.featureUnsupported) }),
            thresholds: thresholds,
            keepAwake: .init(hold: { NSObject() }, release: { _ in }),
            preferences: {
                MeetingPreferences(folder: docs, hook: nil, model: .whisperLargeV3Turbo)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        playing = c
        return c
    }

    // MARK: - the mic

    /// The call talks for ten seconds and the mic hands over nothing but
    /// silence: a problem naming the mic, said on the lamp, until the mic
    /// is heard again.
    func testAMicSilentWhileTheCallTalksIsAProblemNamingItUntilItIsHeard() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...9 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [], "nine seconds is not ten")

        await play(theyTalk(at: .seconds(10)))
        XCTAssertEqual(c.problems, [.cannotHearYourMic("MacBook Pro Microphone")])
        XCTAssertEqual(events, [.started, .problemBegan(.cannotHearYourMic("MacBook Pro Microphone"))])
        XCTAssertEqual(events.last?.hudText, "can't hear your mic — macbook pro microphone")

        await play(both(at: .seconds(11)))
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .problemCleared(.cannotHearYourMic("MacBook Pro Microphone")))
        XCTAssertEqual(events.last?.hudText, "hearing your mic again")

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "mic-silent"), atS: 11),
            .init(.init(rawValue: "mic-silent-cleared"), atS: 12),
        ])
    }

    /// Half a minute with nothing from either side: a quiet room, or no
    /// call at all. A mic is not missed when there is nobody to answer.
    func testBothSidesSilentIsNothingToSay() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...30 {
            await play(silent(at: .seconds(s)))
        }

        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events, [.started])
        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [])
    }

    /// The mac's input muted on purpose is silent on purpose. It ends a
    /// problem that stood, and the lamp says why; while it lasts the call
    /// can talk as long as it likes and nothing is said; the record notes
    /// both ends of it.
    func testAMutedMicIsNotAFaultAndEndsTheProblemThatStood() async throws {
        source.micName = "MacBook Pro Microphone"
        let c = coordinator()
        c.start()
        await source.awaitStart()
        await play(both(at: .zero))
        for s in 1...10 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [.cannotHearYourMic("MacBook Pro Microphone")])

        source.tell(.init(kind: .micMuted, mic: "MacBook Pro Microphone", at: .seconds(11)))
        await until { c.problems.isEmpty }
        XCTAssertEqual(c.problems, [])
        XCTAssertEqual(events.last, .micMuted)
        XCTAssertEqual(events.last?.hudText, "your mic is muted")

        for s in 11...25 {
            await play(theyTalk(at: .seconds(s)))
        }
        XCTAssertEqual(c.problems, [], "muted is not a fault")

        source.tell(.init(kind: .micUnmuted, mic: "MacBook Pro Microphone", at: .seconds(26)))
        await until { events.last == .micUnmuted }
        XCTAssertNil(events.last?.hudText)
        await play(both(at: .seconds(26)))
        XCTAssertEqual(events, [
            .started, .problemBegan(.cannotHearYourMic("MacBook Pro Microphone")),
            .micMuted, .micUnmuted,
        ])

        c.stop()
        await c.untilWrittenOut()
        XCTAssertEqual(records.first?.events, [
            .init(.init(rawValue: "mic-silent"), atS: 11),
            .init(.init(rawValue: "mic-muted"), atS: 11),
            .init(.init(rawValue: "mic-silent-cleared"), atS: 11),
            .init(.init(rawValue: "mic-unmuted"), atS: 26),
        ])
    }

    // MARK: - helpers

    /// A second of both sides talking.
    private func both(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// A second of the far side talking, and the mic handing over silence:
    /// not a quiet room, which is never all zeros, but a mic that is not
    /// there.
    private func theyTalk(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    /// A second of nothing on either side.
    private func silent(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    /// Each chunk, once the coordinator has taken in the one before.
    private func play(_ chunks: MeetingAudioChunk...) async {
        for chunk in chunks {
            source.send(chunk)
            let end = chunk.at + chunk.duration
            for _ in 0..<200 where (playing?.elapsed ?? end) < end {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(20))
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

/// The tap and the mic: chunks as the test sends them, the mic's name, and
/// what it did by itself, told on its own stream.
private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: AsyncStream<MeetingAudioChunk>.Continuation?
    private var told: AsyncStream<MeetingSourceEvent>.Continuation?
    private var events = AsyncStream<MeetingSourceEvent> { $0.finish() }
    private var starts = 0
    private var startsSeen = 0

    var micName: String? {
        get { lock.withLock { _micName } }
        set { lock.withLock { _micName = newValue } }
    }
    private var _micName: String?

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

/// Keeps what it is fed; says nothing.
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
