import XCTest

/// nothing waits forever: an engine that never answers, and a mic that
/// fails on the way out, each cost one press and never the next one. the
/// fakes are `UtteranceMachineTests`'; the engine's `holds` is the hang.
@MainActor
final class UtteranceMachineTimeoutTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var mic: FakeMic!
    private var engine: FakeEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []
    private var pillShowing = false
    private var micForPress: FakeMic?
    /// when set, presses are handed captures the way the app hands them
    /// out — through the slot, which the machine's drop empties.
    private var slot: CaptureSlot?
    private var made: [SlotMic] = []
    /// what the next capture the slot builds will do wrong.
    private var nextCaptureFails: SlotMic.Failure?

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = FakeMic(clock: clock)
        micForPress = mic
        engine = FakeEngine()
        inserter = FakeInserter(clock: clock)
        events = []
        pillShowing = false
        slot = nil
        made = []
        nextCaptureFails = nil
    }

    override func tearDown() async throws {
        // a hung transcription must not outlive its test.
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
            guard let self else { return }
            self.events.append(event)
            switch event {
            case .pill:
                self.pillShowing = true
            case .state:
                self.pillShowing = false
            case .microphoneDropped:
                self.slot?.drop()
            default:
                break
            }
        }
        machine.microphoneForPress = { [weak self] in
            if let slot = self?.slot {
                return .ready(slot.captureForPress())
            }
            guard let self, let mic = self.micForPress else {
                return .refused(.modelNotReady)
            }
            return .ready(mic)
        }
        machine.isPillShowing = { [weak self] in self?.pillShowing ?? false }
        machine.engineVersion = { "v2" }
        return machine
    }

    // MARK: - an engine that never answers

    /// a tenth of a second of audio still gets four seconds: then the press
    /// ends out loud, the lamp goes fast, and the samples are kept for a tap.
    func testAnEngineThatNeverAnswersEndsThePressAndKeepsTheSamples() async {
        let m = machine()
        engine.holds = true
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        await pass(.milliseconds(3_900))
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])

        await pass(.milliseconds(100))
        await settle { !self.pills.isEmpty }
        XCTAssertEqual(pills, [Pill("couldn't transcribe — tap to try again", 4)])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(retryOffers, [true])
        XCTAssertEqual(outcomes, [.couldNotTranscribe])
        XCTAssertEqual(presses.map(\.timedOut), [true])
        XCTAssertEqual(presses.first?.line().contains("timed_out=1"), true)
    }

    /// one take gone unanswered might be a slow moment or a wedge, and only
    /// the app can ask the engine which: it is told to check.
    func testATimeoutAsksForTheEngineToBeChecked() async {
        let m = machine()
        engine.holds = true

        await timeOut(m)

        XCTAssertEqual(engineEvents, [.engineSuspect])
    }

    /// an engine that threw answered: it is not wedged, so nothing is asked.
    func testAnEngineThatThrowsIsNotSuspect() async {
        let m = machine()
        engine.reply = .failure(EngineThrew())

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }
        await pass(TranscriptionDeadline.floor)

        XCTAssertEqual(pills, [Pill("couldn't transcribe — tap to try again", 4)])
        XCTAssertEqual(presses.map(\.timedOut), [false])
        XCTAssertEqual(engineEvents, [])
    }

    /// asleep or locked, the engine isn't what kept you waiting: a deadline
    /// that comes due then waits, and once the mac is back the engine gets a
    /// whole window of its own before the take is given up on.
    func testADeadlineThatComesDueWhileTheMacIsAwayWaitsForItsReturn() async {
        let m = machine()
        engine.holds = true
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.isAway = true
        await pass(TranscriptionDeadline.floor)
        await pass(TranscriptionDeadline.floor)
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])

        // back: a whole window from here, whenever the last one fell.
        m.isAway = false
        await pass(.milliseconds(3_900))
        await pass(.milliseconds(100))
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])

        // and then it is a hang like any other.
        await pass(.milliseconds(3_900))
        XCTAssertEqual(m.state, .transcribing)
        await pass(.milliseconds(100))
        await settle { !self.pills.isEmpty }
        XCTAssertEqual(pills, [Pill("couldn't transcribe — tap to try again", 4)])
        XCTAssertEqual(outcomes, [.couldNotTranscribe])
    }

    /// the real way the mac goes away: the lock comes down while the take is
    /// being written out. the deadline waits through it, and the take is
    /// still the lock's to copy when the engine answers after the unlock.
    func testALockMidTranscriptionHoldsTheDeadline() async {
        let m = machine()
        engine.holds = true
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.captureInterrupted(.systemPaused)
        await pass(TranscriptionDeadline.floor)
        await pass(TranscriptionDeadline.floor)
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])

        m.systemResumed()
        await pass(.milliseconds(3_900))
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])
    }

    /// pressing again over a take three seconds stuck drops it, as it always
    /// has. that is the same evidence as a timeout, so the engine is checked.
    func testAPressThatDropsAHungTakeAsksForTheEngineToBeChecked() async {
        let m = machine()
        engine.holds = true
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }
        await pass(.seconds(3))

        m.keyDown()

        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(outcomes, [.droppedAsHung])
        XCTAssertEqual(engineEvents, [.engineSuspect])
        // the dropped take's deadline says nothing when it comes due.
        await pass(.seconds(1))
        XCTAssertEqual(pills, [])
        XCTAssertEqual(m.state, .recording)
    }

    // MARK: - twice in a row

    /// a tap on the pill replays the samples, and an engine still wedged
    /// doesn't answer those either: the second time is not a slow moment.
    /// the pill says the engine is being restarted, and the samples stay.
    func testARetryWhileStillHungTimesOutTooAndTheEngineIsRestarted() async {
        let m = machine()
        engine.holds = true
        await timeOut(m)

        m.keyDown()
        XCTAssertEqual(m.state, .transcribing)
        await settle { self.engine.heard.count == 2 }
        await pass(.milliseconds(3_900))
        XCTAssertEqual(m.state, .transcribing)
        await pass(.milliseconds(100))
        await settle { self.pills.count == 2 }

        XCTAssertEqual(pills.last, Pill("speech model isn't responding — restarting it", 4))
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(engineEvents, [.engineSuspect, .engineUnresponsive])
        XCTAssertEqual(outcomes, [.couldNotTranscribe, .couldNotTranscribe])
        XCTAssertEqual(presses.map(\.retry), [false, true])
        XCTAssertEqual(presses.map(\.timedOut), [true, true])
        XCTAssertEqual(retryOffers, [true, false, true])
        XCTAssertEqual(mic.starts, 1)
    }

    /// two fresh takes in a row count the same as a take and its retry.
    func testTwoTakesInARowUnansweredRestartTheEngine() async {
        let m = machine()
        engine.holds = true
        await timeOut(m)
        pillShowing = false

        await timeOut(m)

        XCTAssertEqual(mic.starts, 2)
        XCTAssertEqual(pills.last, Pill("speech model isn't responding — restarting it", 4))
        XCTAssertEqual(engineEvents, [.engineSuspect, .engineUnresponsive])
    }

    /// an answer in time, words or an error, says the engine is alive:
    /// the next unanswered take is a first again.
    func testAnAnswerInTimeStartsTheCountOver() async {
        let m = machine()
        engine.holds = true
        await timeOut(m)
        pillShowing = false

        engine.holds = false
        engine.reply = .failure(EngineThrew())
        await hold(m, for: .seconds(1))
        await settle { self.outcomes.count == 2 }
        pillShowing = false

        engine.holds = true
        await timeOut(m)

        XCTAssertEqual(engineEvents, [.engineSuspect, .engineSuspect])
        XCTAssertEqual(pills.last, Pill("couldn't transcribe — tap to try again", 4))
    }

    /// once a restart is asked for, the engine after it starts with a
    /// clean slate.
    func testAfterARestartTheCountStartsOver() async {
        let m = machine()
        engine.holds = true
        for _ in 0..<3 {
            await timeOut(m)
            pillShowing = false
        }

        XCTAssertEqual(
            engineEvents,
            [.engineSuspect, .engineUnresponsive, .engineSuspect]
        )
    }

    /// once the pill has gone, a press is a new sentence: the mic opens and
    /// the take is written out, while the hung call is still out there.
    func testTheNextPressRecordsWhileTheHungCallIsStillOut() async {
        let m = machine()
        engine.holds = true
        await timeOut(m)

        // the hung call keeps waiting; the next one is answered at once.
        engine.holds = false
        engine.reply = .success("second try")
        pillShowing = false
        m.keyDown()
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(mic.starts, 2)
        await pass(.seconds(1))
        m.keyUp()
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertTrue(engine.isWaiting)
        XCTAssertEqual(inserter.inserted, ["Second try."])
        XCTAssertEqual(outcomes, [.couldNotTranscribe, .delivered])
        XCTAssertEqual(retryOffers, [true, false])
    }

    /// the engine answering after the press gave up on it pastes nothing,
    /// says nothing, and leaves the retry where it was.
    func testALateAnswerLandsNowhere() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("too late")
        await timeOut(m)
        let eventsAtTheTimeout = events.count

        engine.release()
        await settle()
        await pass(.seconds(1))

        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(events.count, eventsAtTheTimeout)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(outcomes, [.couldNotTranscribe])
        XCTAssertEqual(retryOffers, [true])
    }

    /// a minute of audio gets fifteen seconds, not four: a long take that
    /// is simply slow is not a hang.
    func testALongTakeGetsAQuarterOfItsLength() async {
        let m = machine()
        mic.samples = [Float](repeating: 0.1, count: 16_000 * 60)
        engine.holds = true
        await hold(m, for: .seconds(60))
        await settle { self.engine.isWaiting }

        await pass(.milliseconds(14_900))
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(pills, [])

        await pass(.milliseconds(100))
        await settle { !self.pills.isEmpty }
        XCTAssertEqual(pills, [Pill("couldn't transcribe — tap to try again", 4)])
        XCTAssertEqual(outcomes, [.couldNotTranscribe])
    }

    /// esc while the engine hangs ends the press once: the deadline it left
    /// behind says nothing when it comes due.
    func testEscWhileHungLeavesNoDeadlineBehind() async {
        let m = machine()
        engine.holds = true
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        XCTAssertTrue(m.escape())
        await pass(.seconds(5))

        XCTAssertEqual(pills, [])
        XCTAssertEqual(retryOffers, [])
        XCTAssertEqual(outcomes, [.cancelled])
    }

    // MARK: - a mic that fails on the way out

    /// a stop that throws — a format the capture can't convert, a device
    /// gone mid-take — loses that take out loud, once. the capture goes with
    /// it, so the next press records through a fresh one rather than
    /// failing the same way for the same cause.
    func testAStopThatFailsCostsOneTakeAndTheNextPressIsFresh() async {
        let m = machine(handingOutCapturesThroughTheSlot: true)
        nextCaptureFails = .stop
        engine.reply = .success("second try")

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }
        pillShowing = false
        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[0].discarded)
        XCTAssertEqual(made.map(\.starts), [1, 1])
        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        XCTAssertEqual(inserter.inserted, ["Second try."])
        XCTAssertEqual(outcomes, [.recordingLost, .delivered])
    }

    /// a stop that never comes back is the same: one take lost, and a
    /// fresh capture for the next.
    func testAStopThatNeverAnswersCostsOneTakeAndTheNextPressIsFresh() async {
        let m = machine(handingOutCapturesThroughTheSlot: true)
        nextCaptureFails = .stopNeverAnswers
        engine.reply = .success("second try")

        await hold(m, for: .seconds(1))
        await pass(.milliseconds(1_500))
        await settle { !self.pills.isEmpty }
        pillShowing = false
        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[0].discarded)
        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        XCTAssertEqual(outcomes, [.recordingLost, .delivered])
    }

    /// a fresh capture that won't start is thrown away too, and the next
    /// press builds another rather than retrying a corpse.
    func testACaptureThatWontStartIsRebuiltByTheNextPress() async {
        let m = machine(handingOutCapturesThroughTheSlot: true)
        nextCaptureFails = .start
        engine.reply = .success("second try")

        m.keyDown()
        await settle { !self.pills.isEmpty }
        m.keyUp()
        pillShowing = false
        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[0].discarded)
        XCTAssertEqual(pills, [Pill("couldn't start recording", 1.6)])
        XCTAssertEqual(outcomes, [.couldNotStartRecording, .delivered])
    }

    // MARK: - helpers

    private func machine(
        handingOutCapturesThroughTheSlot: Bool
    ) -> UtteranceMachine {
        let machine = machine()
        slot = CaptureSlot(
            clock: clock,
            isInUse: { [weak machine] in machine?.state == .recording },
            keepsListening: { false },
            make: { [weak self] in
                let capture = SlotMic(
                    clock: self?.clock ?? FakeUtteranceClock(),
                    fails: self?.nextCaptureFails
                )
                self?.nextCaptureFails = nil
                self?.made.append(capture)
                return capture
            }
        )
        return machine
    }

    private var presses: [PressRecord] {
        events.compactMap {
            if case let .pressEnded(record) = $0 {
                return record
            }
            return nil
        }
    }

    private var outcomes: [PressRecord.Outcome] {
        presses.map(\.outcome)
    }

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

    /// what the machine asked of the engine's keeper.
    private var engineEvents: [UtteranceEvent] {
        events.filter {
            switch $0 {
            case .engineSuspect, .engineUnresponsive:
                true
            default:
                false
            }
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

    /// a one-second take the engine never answers, until the press gives up
    /// on it and the pill says so.
    private func timeOut(_ machine: UtteranceMachine) async {
        await hold(machine, for: .seconds(1))
        await settle { self.engine.isWaiting }
        let pillsBefore = pills.count
        await pass(TranscriptionDeadline.floor)
        await settle { self.pills.count > pillsBefore }
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

private struct EngineThrew: Error {}

/// a capture the slot hands out and throws away, wrong in one chosen way.
@MainActor
private final class SlotMic: DisposableMicCapture {
    enum Failure {
        case start
        case stop
        case stopNeverAnswers
    }

    struct Broken: Error {}

    let deviceDescription: MicDescription? = nil
    private let clock: FakeUtteranceClock
    private let fails: Failure?
    private(set) var starts = 0
    private(set) var discarded = false

    init(clock: FakeUtteranceClock, fails: Failure?) {
        self.clock = clock
        self.fails = fails
    }

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {
        starts += 1
        if fails == .start {
            throw Broken()
        }
        onFirstBuffer(clock.now)
    }

    func stop() async throws -> [Float] {
        switch fails {
        case .stop:
            throw Broken()
        case .stopNeverAnswers:
            // never comes back; the machine stops waiting on it.
            try await clock.sleep(for: .seconds(3_600))
            throw Broken()
        case .start, nil:
            return (0..<1_600).map { Float($0 % 7) * 0.01 }
        }
    }

    func cancel() {}

    func prepare() {}

    func discard() {
        discarded = true
    }
}
