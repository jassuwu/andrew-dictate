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

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = FakeMic(clock: clock)
        micForPress = mic
        engine = FakeEngine()
        inserter = FakeInserter(clock: clock)
        events = []
        pillShowing = false
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
            default:
                break
            }
        }
        machine.microphoneForPress = { [weak self] in
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

    // MARK: - helpers

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
