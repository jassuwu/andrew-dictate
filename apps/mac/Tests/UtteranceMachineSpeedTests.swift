import AppKit
import XCTest

/// the speed work, as a person would notice it: the engine is awake by the
/// time you let go, the engine starts on your words before the chime and
/// the lamp, the clipboard you had is the one you get back, and a restart
/// that never finishes ends in a retry rather than "loading…" for good.
@MainActor
final class UtteranceMachineSpeedTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var mic: FakeMic!
    private var engine: WakeCountingEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []
    private var micForPress: FakeMic?

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = FakeMic(clock: clock)
        micForPress = mic
        engine = WakeCountingEngine()
        inserter = FakeInserter(clock: clock)
        events = []
    }

    override func tearDown() async throws {
        engine.release()
        mic.release()
    }

    private func machine(
        inserter custom: (any Inserter)? = nil
    ) -> UtteranceMachine {
        let machine = UtteranceMachine(
            engine: engine,
            inserter: custom ?? inserter,
            clock: clock,
            dictionary: { [] },
            ownBundleIdentifier: "gg.jass.dictate.dev",
            coolDuration: 0.3
        )
        machine.onEvent = { [weak self] event in
            self?.events.append(event)
        }
        machine.microphoneForPress = { [weak self] in
            guard let mic = self?.micForPress else {
                return .refused(.modelNotReady)
            }
            return .ready(mic)
        }
        machine.isPillShowing = { false }
        machine.engineVersion = { "v2" }
        return machine
    }

    // MARK: - the engine is woken at key-down

    /// the ANE idles down between dictations, and a take handed to it cold
    /// waits on it waking. the press wakes it while you talk.
    func testAPressWakesTheEngine() async {
        let m = machine()

        m.keyDown()

        XCTAssertEqual(m.state, .recording)
        await settle { self.engine.wakes == 1 }
        XCTAssertEqual(engine.heard, [], "the wake is not a take")
    }

    /// the engine that just answered is still awake: a press soon after is
    /// not worth a pass of its own.
    func testAPressSoonAfterATakeDoesNotWakeItAgain() async {
        let m = machine()
        await deliver(m)
        XCTAssertEqual(engine.wakes, 1)

        await pass(.seconds(5))
        m.keyDown()
        await settle()

        XCTAssertEqual(engine.wakes, 1)
    }

    /// once it has been idle a while, the next press wakes it again.
    func testAPressAfterAnIdleSpellWakesItAgain() async {
        let m = machine()
        await deliver(m)

        await pass(UtteranceMachine.engineStaysAwake + .seconds(1))
        m.keyDown()

        await settle { self.engine.wakes == 2 }
    }

    /// a press the app refused records nothing, so nothing is coming for
    /// the engine to be awake for.
    func testARefusedPressDoesNotWakeTheEngine() async {
        let m = machine()
        micForPress = nil

        m.keyDown()
        await settle()

        XCTAssertEqual(engine.wakes, 0)
    }

    /// the wake is the engine's to answer in its own time: one that never
    /// does holds up neither the press nor the take after it.
    func testAWakeThatNeverAnswersHoldsNothingUp() async {
        let m = machine()
        engine.holdsWake = true
        engine.reply = .success("still here")

        m.keyDown()
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(mic.starts, 1)
        await pass(.seconds(1))
        m.keyUp()

        await settle { self.inserter.inserted == ["Still here."] }
    }

    // MARK: - key-up: the engine first

    /// at key-up the engine starts on your words before the chime plays or
    /// the lamp changes: neither is worth a millisecond of its time. the
    /// handler holds the main thread, so the engine can only have been
    /// asked if it was asked before the chime was.
    func testTheEngineIsAskedBeforeTheEndChimeAndTheLamp() async {
        let m = machine()
        engine.reply = .success("first")
        let engine = engine!
        var askedByChime: Bool?
        var askedByLamp: Bool?
        m.onEvent = { event in
            switch event {
            case .chime(.end):
                askedByChime = Self.waitHoldingMain { engine.isAsked }
            case .state(.transcribing, _):
                askedByLamp = Self.waitHoldingMain { engine.isAsked }
            default:
                break
            }
        }

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        await settle { !self.inserter.inserted.isEmpty }

        XCTAssertEqual(askedByChime, true)
        XCTAssertEqual(askedByLamp, true)
        XCTAssertEqual(inserter.inserted, ["First."])
    }

    /// where the words go and what the clipboard holds are read while the
    /// engine works, not after it: by the time the transcript lands, only
    /// the paste is left.
    func testTheTargetAndTheClipboardAreReadWhileTheEngineWorks() async {
        let reading = TargetReadingInserter(clock: clock)
        reading.anchor = FakeAnchor(
            targetBundleIdentifier: "com.apple.TextEdit",
            before: "it failed because"
        )
        let m = machine(inserter: reading)
        engine.holds = true
        engine.reply = .success("the cache was cold")

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        await settle { self.engine.isAsked }
        await settle()

        XCTAssertEqual(reading.targetReads, 1)
        XCTAssertEqual(reading.pasteboardReadsAhead, 1)
        XCTAssertEqual(reading.inserted, [])

        engine.release()
        await settle { !reading.inserted.isEmpty }
        // the caret read during the wait still decides the join.
        XCTAssertEqual(reading.inserted, [" the cache was cold."])
    }

    /// a take the lock ends is copied, never pasted, so there is no
    /// clipboard to put back and nothing to read ahead.
    func testATakeTheLockCopiesReadsNoClipboardAhead() async {
        let reading = TargetReadingInserter(clock: clock)
        let m = machine(inserter: reading)
        engine.reply = .success("kept for later")

        m.keyDown()
        await pass(.seconds(1))
        m.captureInterrupted(.systemPaused)
        await settle { !reading.copied.isEmpty }

        XCTAssertEqual(reading.pasteboardReadsAhead, 0)
        XCTAssertEqual(reading.copied, ["Kept for later."])
    }

    // MARK: - nothing at key-down waits on another app

    /// the standby anchor is AX — IPC to whatever app is in front — and an
    /// app that has stopped answering must not hold up the press: the lamp
    /// and the mic come first, the read is off the main actor, and a take
    /// whose standby never came back is written out without it.
    func testAStandbyAnchorThatNeverAnswersHoldsUpNothing() async {
        let reading = TargetReadingInserter(clock: clock)
        reading.holdsAnchor = true
        let m = machine(inserter: reading)
        engine.reply = .success("still here")

        m.keyDown()
        XCTAssertTrue(events.contains(.state(.recording, fastDismiss: false)))
        XCTAssertEqual(mic.starts, 1)
        await settle { reading.anchorReads == 1 }
        XCTAssertEqual(m.state, .recording)

        await pass(.seconds(1))
        m.keyUp()
        await settle { reading.inserted == ["Still here."] }
        XCTAssertEqual(reading.standbys, [nil])

        // its answer, long after the take, stands in for nothing.
        reading.answerAnchor()
        await settle()
        XCTAssertEqual(reading.standbys, [nil])
    }

    /// key-up finds one of our own windows in front, so key-down's anchor
    /// stands in, read while the key was held.
    func testTheStandbyReadAtKeyDownStandsInAtKeyUp() async {
        let reading = TargetReadingInserter(clock: clock)
        reading.anchor = nil
        reading.standby = FakeAnchor(targetBundleIdentifier: "com.apple.Notes")
        let m = machine(inserter: reading)
        engine.reply = .success("into notes")

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        await settle { reading.inserted == ["Into notes."] }

        XCTAssertEqual(reading.anchorReads, 1)
        XCTAssertEqual(reading.standbys, ["com.apple.Notes"])
    }

    // MARK: - helpers

    /// waits on another thread's answer without letting the main thread
    /// go: whatever the machine does next has to wait too.
    private static func waitHoldingMain(
        upTo seconds: TimeInterval = 2,
        until isDone: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone() {
                return true
            }
            usleep(1_000)
        }
        return isDone()
    }

    private func deliver(_ m: UtteranceMachine) async {
        engine.reply = .success("done")
        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        await settle { !self.inserter.inserted.isEmpty }
        await pass(.milliseconds(400))
        XCTAssertEqual(m.state, .idle)
    }

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

// MARK: - fakes

/// `FakeEngine`, and it counts the wakes it is asked for. a held wake waits
/// for `release()`, the way an engine that never answers would.
final class WakeCountingEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: Result<String, any Error> = .success("hello")
    private var _heard: [[Float]] = []
    private var _wakes = 0
    private var _holdsWake = false
    private var _holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var reply: Result<String, any Error> {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    var holdsWake: Bool {
        get { lock.withLock { _holdsWake } }
        set { lock.withLock { _holdsWake = newValue } }
    }

    /// while set, a take waits for `release()`.
    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    var heard: [[Float]] {
        lock.withLock { _heard }
    }

    var wakes: Int {
        lock.withLock { _wakes }
    }

    var isAsked: Bool {
        lock.withLock { !_heard.isEmpty }
    }

    func prewarm(
        progressHandler: (@Sendable (TranscriptionPreparationUpdate) -> Void)?
    ) async throws {}

    func wake() async {
        let holds = lock.withLock {
            _wakes += 1
            return _holdsWake
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
            }
        }
    }

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
            _holdsWake = false
            let released = waiting
            waiting = []
            return released
        }
        for continuation in released {
            continuation.resume()
        }
    }
}

/// `FakeInserter`, and it says when it was asked where the words go and
/// to read the clipboard ahead.
@MainActor
final class TargetReadingInserter: Inserter {
    var anchor: FakeAnchor? = FakeAnchor(
        targetBundleIdentifier: "com.apple.TextEdit"
    )
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []
    private(set) var targetReads = 0
    private(set) var pasteboardReadsAhead = 0
    /// what key-down's read finds: the standby.
    var standby: FakeAnchor? = FakeAnchor(
        targetBundleIdentifier: "com.apple.TextEdit"
    )
    /// while set, that read waits for `answerAnchor()`: an app in front
    /// that has stopped answering AX.
    var holdsAnchor = false
    private(set) var anchorReads = 0
    /// the standby each key-up read was handed, by its app.
    private(set) var standbys: [String?] = []
    private var heldAnchor: CheckedContinuation<Void, Never>?
    private let clock: FakeUtteranceClock

    init(clock: FakeUtteranceClock) {
        self.clock = clock
    }

    func readAnchor() async -> (any InsertionAnchor)? {
        anchorReads += 1
        if holdsAnchor {
            await withCheckedContinuation { heldAnchor = $0 }
        }
        return standby
    }

    func answerAnchor() {
        let held = heldAnchor
        heldAnchor = nil
        held?.resume()
    }

    func captureAnchorUnlessOurs() -> (any InsertionAnchor)? {
        anchor
    }

    func readTarget(
        standby: (any InsertionAnchor)?
    ) async -> InsertionTarget {
        targetReads += 1
        standbys.append(standby?.targetBundleIdentifier)
        let target: (any InsertionAnchor)? = anchor ?? standby
        return InsertionTarget(
            anchor: target,
            textBeforeCursor: target?.textBeforeCursor()
        )
    }

    func readPasteboardAhead() {
        pasteboardReadsAhead += 1
    }

    func insert(
        _ text: String,
        at anchor: (any InsertionAnchor)?
    ) async -> PasteOutcome {
        inserted.append(text)
        return PasteOutcome(result: .pasted, insertedAt: clock.now)
    }

    func copy(
        _ text: String,
        because reason: LeftOnPasteboardReason
    ) async -> PasteOutcome {
        copied.append(text)
        return PasteOutcome(
            result: .leftOnPasteboard(reason),
            insertedAt: clock.now
        )
    }
}

/// the clipboard you had is read while the engine works, and read again
/// at the paste if anything was copied over it meanwhile: what comes back
/// after the paste is what was there just before it. asserted on a
/// private pasteboard; nothing here posts a keystroke.
@MainActor
final class PasteboardReadAheadTests: XCTestCase {
    func testAClipboardUntouchedSinceKeyUpKeepsTheEarlyRead() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)

        let early = Paster.snapshot(of: pasteboard)
        let restored = Paster.snapshotToRestore(early: early, on: pasteboard)

        XCTAssertNotNil(early)
        XCTAssertEqual(restored?.changeCount, early?.changeCount)
        XCTAssertEqual(restored?.string, "what you had")
    }

    func testAClipboardCopiedOverDuringTheWaitIsReadAgain() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)
        let early = Paster.snapshot(of: pasteboard)

        // ⌘C while the engine was working.
        pasteboard.clearContents()
        pasteboard.setString("copied while waiting", forType: .string)
        let restored = Paster.snapshotToRestore(early: early, on: pasteboard)

        XCTAssertEqual(restored?.string, "copied while waiting")
        XCTAssertEqual(restored?.changeCount, pasteboard.changeCount)
    }

    func testNoEarlyReadIsReadAtThePaste() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)

        let restored = Paster.snapshotToRestore(early: nil, on: pasteboard)

        XCTAssertEqual(restored?.string, "what you had")
    }
}

/// a restart of a model already on disk takes seconds. one still going
/// after a minute has wedged, and the speech model is `.failed`: the next
/// press retries out loud instead of hearing "loading the speech model…"
/// for good.
@MainActor
final class EngineRestartDeadlineTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var held: CheckedContinuation<Void, Never>?
    private var outcome: EngineRestart.Outcome?

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        held = nil
        outcome = nil
    }

    override func tearDown() async throws {
        held?.resume()
        held = nil
    }

    func testARestartThatFinishesIsReady() async {
        let outcome = await EngineRestart.run(clock: clock) {}

        XCTAssertEqual(outcome, .restarted)
        XCTAssertEqual(outcome.preparationState, .ready)
    }

    func testARestartThatThrowsHasFailed() async {
        let outcome = await EngineRestart.run(clock: clock) {
            throw RestartFailure()
        }

        XCTAssertEqual(outcome.preparationState, .failed)
        XCTAssertEqual(
            outcome.preparationState.earlyPress,
            .retryPreparing
        )
    }

    func testARestartStillGoingAfterAMinuteHasFailed() async {
        let clock = clock!
        let restart = Task { @MainActor in
            self.outcome = await EngineRestart.run(clock: clock) { [weak self] in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in self?.held = continuation }
                }
            }
        }
        await settle { self.held != nil }
        // the deadline's sleep, queued before the clock moves.
        try? await Task.sleep(for: .milliseconds(20))

        clock.advance(by: EngineRestart.deadline - .milliseconds(100))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(outcome, "a slow restart is still a restart")

        clock.advance(by: .milliseconds(100))
        await restart.value

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(outcome?.preparationState, .failed)
        // and the next press says so and tries again.
        XCTAssertEqual(
            outcome?.preparationState.earlyPress,
            .retryPreparing
        )
        XCTAssertEqual(EngineRestart.deadline, .seconds(60))
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

private struct RestartFailure: Error {}

/// the first press after a monitor, the lid or airpods used to build its
/// capture from nothing: 143 ms to start against 53 ms warm. now the
/// fresh one is built once the hardware settles — engine made, default mic
/// bound, graph prepared — and, with pre-roll off, not started: the mic is
/// never live at idle.
@MainActor
final class CaptureSlotWarmTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var made: [PreparingCapture] = []
    private var preRoll = false

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        made = []
        preRoll = false
    }

    private func slot() -> CaptureSlot {
        CaptureSlot(
            clock: clock,
            isInUse: { false },
            keepsListening: { [weak self] in self?.preRoll ?? false },
            make: { [weak self] in
                let capture = PreparingCapture()
                self?.made.append(capture)
                return capture
            }
        )
    }

    func testTheCaptureAfterADeviceChangeIsReadyBeforeThePress() async {
        let slot = slot()
        _ = slot.captureForPress()

        slot.deviceChanged()
        await pass(.milliseconds(500))

        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made[1].prepares, 1)
        XCTAssertTrue(slot.captureForPress() === made[1])
        XCTAssertEqual(made.count, 2, "the press found it built")
    }

    /// a capture the machine gave up on is replaced the same way, once
    /// whatever wedged it has had a moment to settle.
    func testADroppedCaptureIsReplacedOnceTheHardwareSettles() async {
        let slot = slot()
        _ = slot.captureForPress()

        slot.drop()
        XCTAssertEqual(made.count, 1)
        await pass(.milliseconds(500))

        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
        XCTAssertTrue(slot.captureForPress() === made[1])
    }

    /// pre-roll switched off: the listening capture goes, and the one
    /// after it is ready without listening.
    func testSwitchingPreRollOffLeavesAReadyCapture() {
        preRoll = true
        let slot = slot()
        slot.prepare()

        preRoll = false
        slot.listeningChanged()

        XCTAssertEqual(made[0].discards, 1)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[1].prepares, 1)
    }

    private func pass(_ duration: Duration) async {
        try? await Task.sleep(for: .milliseconds(10))
        clock.advance(by: duration)
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
final class PreparingCapture: DisposableMicCapture {
    let deviceDescription: MicDescription? = nil
    private(set) var prepares = 0
    private(set) var discards = 0

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {}

    func stop() async throws -> [Float] {
        []
    }

    func cancel() {}

    func prepare() {
        prepares += 1
    }

    func discard() {
        discards += 1
    }
}

private extension Paster.Snapshot {
    var string: String? {
        items.first?.representations
            .first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
            .map { String(decoding: $0.data, as: UTF8.self) }
    }
}
