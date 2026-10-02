import XCTest

/// the dictation path from key-down to outcome, driven through the machine's
/// own inputs with a fake mic, engine, inserter and clock. what is asserted
/// is what a person would notice: what was pasted, which pill, how the lamp
/// left, what was kept.
@MainActor
final class UtteranceMachineTests: XCTestCase {
    private var clock: FakeClock!
    private var mic: FakeMic!
    private var engine: FakeEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []
    /// the coordinator's half of "is a pill up": shown by a pill, cleared by
    /// the next state change, or by a test saying its time ran out.
    private var pillShowing = false
    /// nil is the app refusing the press itself — a model still loading, a
    /// missing grant, no input device.
    private var micForPress: FakeMic?

    override func setUp() async throws {
        clock = FakeClock()
        mic = FakeMic(clock: clock)
        micForPress = mic
        engine = FakeEngine()
        inserter = FakeInserter(clock: clock)
        events = []
        pillShowing = false
    }

    override func tearDown() async throws {
        // a held transcription must not outlive its test.
        engine.release()
    }

    private func machine() -> UtteranceMachine {
        let machine = UtteranceMachine(
            engine: engine,
            inserter: inserter,
            clock: clock,
            dictionary: { [] },
            ownBundleIdentifier: "gg.jass.dictate.dev",
            coolDuration: 0.3
        )
        machine.onEvent = { [weak self] event in
            guard let self else { return }
            self.events.append(event)
            switch event {
            case .pill:
                self.pillShowing = true
            case .state:
                self.pillShowing = false
            default:
                break
            }
        }
        machine.microphoneForPress = { [weak self] in self?.micForPress }
        machine.isPillShowing = { [weak self] in self?.pillShowing ?? false }
        return machine
    }

    // MARK: - delivered

    func testAHeldPressIsDelivered() async {
        let m = machine()
        engine.reply = .success("the build failed")

        m.keyDown()
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(mic.starts, 1)
        await pass(.seconds(1))
        m.keyUp()
        XCTAssertEqual(m.state, .transcribing)
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(inserter.inserted, ["The build failed."])
        XCTAssertEqual(engine.heard, [mic.samples])
        XCTAssertEqual(completions, [.delivered])
        XCTAssertEqual(archived, [.init(heard: "the build failed", inserted: "The build failed.")])
        XCTAssertTrue(events.contains(.dictated("The build failed.")))
        XCTAssertTrue(events.contains(.transcribed(heard: "the build failed", inserted: "The build failed.")))
        // success is silent.
        XCTAssertEqual(pills, [])
        XCTAssertEqual(chimes, [.start, .end])

        // the lamp holds through its afterglow, then goes.
        XCTAssertEqual(m.state, .transcribing)
        await pass(.milliseconds(400))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states, [
            .init(.recording, fast: false),
            .init(.transcribing, fast: false),
            .init(.idle, fast: true),
        ])
    }

    // MARK: - left on the pasteboard

    /// a password field gets the words, concealed, on the clipboard — and a
    /// password is not a dictation, so nothing is kept.
    func testASecureFieldLeavesItOnThePasteboardAndKeepsNothing() async {
        let m = machine()
        engine.reply = .success("hunter two")
        inserter.result = .leftOnPasteboard(.secureField)

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("copied — secure field · ⌘V to paste", 4)])
        XCTAssertEqual(completions, [.leftOnPasteboardSecure])
        XCTAssertEqual(archived, [])
        // the pill is the goodbye here, not the afterglow.
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: false))
    }

    /// focus moved during the wait: the words reached you another way, so
    /// they still count and are still kept.
    func testFocusThatMovedLeavesItOnThePasteboardAndStillKeepsIt() async {
        let m = machine()
        engine.reply = .success("ship it")
        inserter.result = .leftOnPasteboard(.focusChanged)

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("copied — focus changed · ⌘V to paste", 4)])
        XCTAssertEqual(completions, [.leftOnPasteboard])
        XCTAssertEqual(archived, [.init(heard: "ship it", inserted: "Ship it.")])
        XCTAssertTrue(events.contains(.dictated("Ship it.")))
        XCTAssertEqual(m.state, .idle)
    }

    /// the one hand-off with nothing sitting on the clipboard: it says so,
    /// and the words do not count as dictated.
    func testABusyClipboardSaysNothingWasCopied() async {
        let m = machine()
        engine.reply = .success("ship it")
        inserter.result = .leftOnPasteboard(.pasteboardUnavailable)

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("the clipboard is busy — nothing was copied", 4)])
        XCTAssertFalse(events.contains(.dictated("Ship it.")))
    }

    // MARK: - nothing to say

    /// silence must not wear the success afterglow — and silence is an
    /// answer, not a failure, so there is nothing to try again.
    func testSilenceSaysHeardNothing() async {
        let m = machine()
        engine.reply = .success("")

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("heard nothing", 2.4)])
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(completions, [])
        XCTAssertFalse(events.contains(.retryOffered(true)))
    }

    /// a key nobody meant to press asked no question, so it gets no answer.
    func testABrushUnderThreeHundredMillisecondsEndsSilently() async {
        let m = machine()
        engine.reply = .success("")

        await hold(m, for: .milliseconds(200))
        await settle { m.state == .idle }
        await settle()

        XCTAssertEqual(pills, [])
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(inserter.inserted, [])
    }

    /// the hotkey's own cancel, before the chime: no sound at all.
    func testABrushTheHotkeyCancelsMakesNoSound() async {
        let m = machine()

        m.keyDown()
        await pass(.milliseconds(50))
        m.keyCancelled()
        await pass(.milliseconds(200))

        XCTAssertEqual(chimes, [])
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
    }

    // MARK: - couldn't transcribe

    /// the samples are kept, and a press while the pill still says so means
    /// "that one": it replays them rather than opening the mic.
    func testAFailedTranscriptionArmsARetryTheNextPressReplays() async {
        let m = machine()
        engine.reply = .failure(EngineFailure())

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("couldn't transcribe — tap to try again", 4)])
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(retryOffers, [true])
        XCTAssertEqual(completions, [])

        engine.reply = .success("the build failed")
        m.keyDown()
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(mic.starts, 1)
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(engine.heard, [mic.samples, mic.samples])
        XCTAssertEqual(inserter.inserted, ["The build failed."])
        XCTAssertEqual(completions, [.delivered])
        XCTAssertEqual(retryOffers, [true, false])
        // the key's eventual release ends nothing: there is no recording.
        m.keyUp()
        XCTAssertEqual(mic.stops, 1)
    }

    /// once the pill has gone, a press is a new sentence, and the lost one
    /// stops being offered.
    func testAPressAfterThePillHasGoneRecordsAgain() async {
        let m = machine()
        engine.reply = .failure(EngineFailure())
        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        pillShowing = false
        m.keyDown()

        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(mic.starts, 2)
        XCTAssertEqual(engine.heard.count, 1)
        XCTAssertEqual(retryOffers, [true, false])
    }

    /// two minutes and the lost sentence is somebody else's sentence.
    func testTheRetryLapsesAfterTwoMinutes() async {
        let m = machine()
        engine.reply = .failure(EngineFailure())
        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        await pass(.seconds(119))
        XCTAssertEqual(retryOffers, [true])
        await pass(.seconds(1))
        XCTAssertEqual(retryOffers, [true, false])
    }

    /// the menu's door to the same samples.
    func testTheMenuRetriesTheLostSentence() async {
        let m = machine()
        engine.reply = .failure(EngineFailure())
        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        engine.reply = .success("the build failed")
        m.retryLastFailure()
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(engine.heard, [mic.samples, mic.samples])
        XCTAssertEqual(retryOffers, [true, false])
    }

    // MARK: - helpers

    private var pills: [Pill] {
        events.compactMap {
            if case let .pill(message, duration) = $0 {
                return Pill(message, duration)
            }
            return nil
        }
    }

    private var states: [StateChange] {
        events.compactMap {
            if case let .state(state, fast) = $0 {
                return StateChange(state, fast: fast)
            }
            return nil
        }
    }

    private var chimes: [UtteranceMachine.Chime] {
        events.compactMap {
            if case let .chime(chime) = $0 {
                return chime
            }
            return nil
        }
    }

    private var retryOffers: [Bool] {
        events.compactMap {
            if case let .retryOffered(offered) = $0 {
                return offered
            }
            return nil
        }
    }

    private var completions: [UtteranceTimeline.CompletionStage] {
        events.compactMap {
            if case let .timelineCompleted(timeline) = $0 {
                return timeline.completionStage
            }
            return nil
        }
    }

    private var archived: [Kept] {
        events.compactMap {
            if case let .archiveRecord(_, heard, inserted) = $0 {
                return Kept(heard: heard, inserted: inserted)
            }
            return nil
        }
    }

    /// a press held for `duration`, then let go.
    private func hold(
        _ machine: UtteranceMachine,
        for duration: Duration
    ) async {
        machine.keyDown()
        await pass(duration)
        machine.keyUp()
    }

    /// time passes on the machine's clock. whatever is queued gets a turn to
    /// start waiting on it first, and whatever wakes gets a turn to run.
    private func pass(_ duration: Duration) async {
        await settle()
        clock.advance(by: duration)
        await settle()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func settle(
        until isDone: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if isDone() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never settled", file: file, line: line)
    }
}

// MARK: - what the tests read

private struct Pill: Equatable, CustomStringConvertible {
    let message: String
    let duration: TimeInterval

    init(_ message: String, _ duration: TimeInterval) {
        self.message = message
        self.duration = duration
    }

    var description: String { "\(message) (\(duration)s)" }
}

private struct StateChange: Equatable {
    let state: UtteranceMachine.State
    let fast: Bool

    init(_ state: UtteranceMachine.State, fast: Bool) {
        self.state = state
        self.fast = fast
    }
}

private struct Kept: Equatable {
    let heard: String
    let inserted: String
}

// MARK: - fakes

/// a clock the test moves by hand. a sleep wakes when the hand passes its
/// deadline, or throws the moment its task is cancelled.
private final class FakeClock: UtteranceClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]

    var now: ContinuousClock.Instant {
        lock.withLock { origin + offset }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        sleepers[id] = Sleeper(
                            deadline: offset + duration,
                            continuation: continuation
                        )
                    }
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by amount: Duration) {
        let due = lock.withLock {
            offset += amount
            let due = sleepers.filter { $0.value.deadline <= offset }
            for id in due.keys {
                sleepers.removeValue(forKey: id)
            }
            return due.values.map(\.continuation)
        }
        for continuation in due {
            continuation.resume()
        }
    }
}

private struct MicFailure: Error {}

@MainActor
private final class FakeMic: MicCapture {
    let samples: [Float] = (0..<1_600).map { Float($0 % 7) * 0.01 }
    var failsToStart = false
    var failsToStop = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private let clock: FakeClock

    init(clock: FakeClock) {
        self.clock = clock
    }

    /// the first buffer lands at once: a fake mic has nothing to warm up.
    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) throws {
        if failsToStart {
            throw MicFailure()
        }
        starts += 1
        onFirstBuffer(clock.now)
    }

    func stop() throws -> [Float] {
        if failsToStop {
            throw MicFailure()
        }
        stops += 1
        return samples
    }

    func cancel() {
        cancels += 1
    }
}

private struct EngineFailure: Error {}

/// answers with `reply`, or — while `holds` is set — waits for the test to
/// `release()` it, the way a slow or hung engine would.
private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: Result<String, any Error> = .success("hello")
    private var _holds = false
    private var _heard: [[Float]] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var reply: Result<String, any Error> {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    var heard: [[Float]] {
        lock.withLock { _heard }
    }

    var isWaiting: Bool {
        lock.withLock { !waiting.isEmpty }
    }

    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws {}

    func transcribe(_ samples: [Float]) async throws -> String {
        let holds = lock.withLock {
            _heard.append(samples)
            return _holds
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
            }
        }
        return try reply.get()
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
}

@MainActor
private struct FakeAnchor: InsertionAnchor {
    var targetBundleIdentifier: String?
    var before: String?

    func textBeforeCursor() -> String? {
        before
    }

    func yieldFocusBackToAnchor() async -> Bool {
        true
    }

    func revalidationDecision() -> FocusRevalidationDecision {
        .paste
    }
}

@MainActor
private final class FakeInserter: Inserter {
    var anchor: FakeAnchor? = FakeAnchor(
        targetBundleIdentifier: "com.apple.TextEdit"
    )
    var result: PasteResult = .pasted
    private(set) var inserted: [String] = []
    private let clock: FakeClock

    init(clock: FakeClock) {
        self.clock = clock
    }

    func captureAnchor() -> (any InsertionAnchor)? {
        anchor
    }

    func captureAnchorUnlessOurs() -> (any InsertionAnchor)? {
        anchor
    }

    func insert(
        _ text: String,
        at anchor: (any InsertionAnchor)?
    ) async -> PasteOutcome {
        inserted.append(text)
        return PasteOutcome(result: result, insertedAt: clock.now)
    }
}
