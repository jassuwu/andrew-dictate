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

    // MARK: - helpers

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
