import XCTest

/// only you throw an utterance away. the display is held awake while the
/// mic is live, and when the mac sleeps or locks anyway the take is kept:
/// written out, copied rather than pasted, and said once you are back.
/// the fakes are `UtteranceMachineTests`'.
@MainActor
final class UtteranceMachineInterruptionTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var mic: FakeMic!
    private var engine: FakeEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = FakeMic(clock: clock)
        engine = FakeEngine()
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
            guard let self else {
                return .refused(.modelNotReady)
            }
            return .ready(self.mic)
        }
        machine.isPillShowing = { false }
        machine.engineVersion = { "v2" }
        return machine
    }

    // MARK: - the display stays awake while the mic is live

    /// held from key-down, let go the moment the mic is asked to stop, not
    /// when the words land: transcribing needs nobody looking.
    func testTheDisplayIsHeldAwakeOnlyWhileTheMicIsLive() async {
        let m = machine()
        m.keyDown()
        XCTAssertEqual(keepAwake, [true])
        await pass(.seconds(1))
        XCTAssertEqual(keepAwake, [true])

        engine.holds = true
        m.keyUp()
        XCTAssertEqual(keepAwake, [true, false])
        engine.release()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(keepAwake, [true, false])
    }

    /// whatever ends the take lets the display sleep again, once, and a
    /// take that never reached the mic never held it.
    func testEveryEndingLetsTheDisplaySleep() async {
        let endings: [(String, @MainActor (UtteranceMachine) async -> Void)] = [
            ("released", { $0.keyUp() }),
            ("esc", { _ = $0.escape() }),
            ("brushed", { $0.keyCancelled() }),
            ("the lock", { $0.captureInterrupted(.systemPaused) }),
            ("the mic changed", { $0.captureInterrupted(.deviceChanged) }),
            ("the cap", { _ = $0.capReached() }),
            ("the speech model went", { $0.abandon() }),
        ]
        for (ending, end) in endings {
            events = []
            let m = machine()
            m.keyDown()
            await pass(.seconds(1))
            await end(m)
            await settle()
            XCTAssertEqual(keepAwake, [true, false], ending)
            m.abandon()
            await pass(.seconds(2))
        }
    }

    /// hands-free is the take most likely to run for minutes untouched.
    func testALockedRecordingHoldsTheDisplayUntilTheTapThatEndsIt() async {
        let m = machine()
        m.doubleTapped()
        await pass(.seconds(90))
        XCTAssertEqual(keepAwake, [true])

        m.keyUp()
        XCTAssertEqual(keepAwake, [true, false])
    }

    /// a mic that refuses, never answers, or has no device behind it ends
    /// the take before it was live, and lets go all the same.
    func testAMicThatNeverWentLiveLetsTheDisplaySleep() async {
        let failures: [(String, @MainActor () -> Void)] = [
            ("refused", { self.mic.failsToStart = true }),
            ("no device", { self.mic.hasNoDevice = true }),
            ("never answered", { self.mic.holdsStart = true }),
        ]
        for (failure, arrange) in failures {
            events = []
            mic.release()
            mic = FakeMic(clock: clock)
            arrange()
            let m = machine()
            m.keyDown()
            await pass(.seconds(2))
            XCTAssertEqual(keepAwake, [true, false], failure)
            XCTAssertEqual(m.state, .idle, failure)
        }
    }

    /// a stop that throws, or never comes back, has already let the
    /// display go: the take was over the moment it was asked.
    func testAMicThatWillNotStopHasAlreadyLetTheDisplayGo() async {
        for holds in [false, true] {
            events = []
            mic.release()
            mic = FakeMic(clock: clock)
            mic.failsToStop = !holds
            mic.holdsStop = holds
            let m = machine()
            await hold(m, for: .seconds(1))
            await pass(.seconds(2))
            XCTAssertEqual(keepAwake, [true, false])
            XCTAssertEqual(outcomes, [.recordingLost])
        }
    }

    // MARK: - the lock ends the take and keeps it

    /// the mic is stopped, not thrown away; what it heard is written out
    /// and left on the clipboard — the field it was going to is behind the
    /// lock screen — and kept in history like any copy.
    func testTheLockMidRecordingKeepsTheTakeOnTheClipboard() async {
        let m = machine()
        engine.reply = .success("the whole paragraph")
        m.keyDown()
        await pass(.seconds(3))

        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }

        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(mic.cancels, 0)
        XCTAssertEqual(engine.heard, [mic.samples])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.copied, ["The whole paragraph."])
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.locked)])
        XCTAssertEqual(presses.first?.stages.keyUp, 3_000)
        XCTAssertEqual(archived, [
            .init(heard: "the whole paragraph", inserted: "The whole paragraph."),
        ])
        XCTAssertTrue(events.contains(.dictated("The whole paragraph.")))
        XCTAssertEqual(m.state, .idle)
    }

    /// the pill would land on the lock screen and be gone before anyone
    /// saw it. it waits for the mac to come back, and is said once.
    func testThePillWaitsUntilYouAreBack() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }
        await pass(.seconds(60))
        XCTAssertEqual(pills, [])

        m.systemResumed()
        XCTAssertEqual(pills, [Self.copiedBeforeTheLock])
        m.systemResumed()
        XCTAssertEqual(pills, [Self.copiedBeforeTheLock])
    }

    /// back before the words were: the pill rides the copy, as any other
    /// copy's does.
    func testBackBeforeTheWordsAreWrittenOutThePillRidesTheCopy() async {
        let m = machine()
        engine.holds = true
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { self.engine.isWaiting }

        m.systemResumed()
        XCTAssertEqual(pills, [])
        engine.release()
        await settle { !self.outcomes.isEmpty }

        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.copied, ["Hello."])
        XCTAssertEqual(pills, [Self.copiedBeforeTheLock])
    }

    /// the words were already with the engine when the lock came down:
    /// they are still written out, and still copied rather than pasted —
    /// the field they were going to is behind the lock screen too.
    func testTheLockWhileTranscribingStillCopiesWhatWasSaid() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("almost there")
        await hold(m, for: .seconds(2))
        await settle { self.engine.isWaiting }

        m.captureInterrupted(.systemPaused)
        XCTAssertEqual(m.state, .transcribing)
        engine.release()
        await settle { !self.outcomes.isEmpty }

        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.copied, ["Almost there."])
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.locked)])
        XCTAssertEqual(archived.map(\.inserted), ["Almost there."])
        XCTAssertEqual(pills, [])

        m.systemResumed()
        XCTAssertEqual(pills, [Self.copiedBeforeTheLock])
    }

    /// esc is still the one way to throw a take away: nothing is copied,
    /// and nothing waits to be said.
    func testEscStillThrowsTheTakeAway() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(2))

        XCTAssertTrue(m.escape())
        await settle()

        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(inserter.copied, [])
        XCTAssertEqual(outcomes, [.cancelled])

        m.captureInterrupted(.systemPaused)
        m.systemResumed()
        await settle()
        XCTAssertEqual(inserter.copied, [])
        XCTAssertEqual(pills, [])
        XCTAssertEqual(outcomes, [.cancelled])
    }

    /// the lock touched the last take, not the next one: a take after you
    /// are back pastes as any other.
    func testTheTakeAfterTheLockPastesAgain() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))
        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }
        m.systemResumed()
        await pass(.seconds(1))

        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(inserter.copied, ["Hello."])
        XCTAssertEqual(inserter.inserted, ["Hello."])
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.locked), .delivered])
    }

    /// the press log says the lock kept it, never that it was thrown away,
    /// and the line reads back.
    func testThePressLogSaysTheLockKeptIt() async throws {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))
        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }

        let record = try XCTUnwrap(presses.first)
        XCTAssertEqual(record.outcome.name, "left-on-pasteboard")
        XCTAssertEqual(record.outcome.why, "locked")
        let decoded = try JSONDecoder().decode(
            PressRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.outcome, .leftOnPasteboard(.locked))
    }

    // MARK: - a stop that spans the sleep

    /// the mac slept with the stop still out. the time asleep counted
    /// against the mic, and its answer could only come once the mac was
    /// back: whatever it hands over then is still the take.
    func testAStopThatAnswersAfterTheSleepStillCounts() async {
        let m = machine()
        mic.holdsStop = true
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { self.mic.isStopping }

        await pass(.seconds(8 * 60 * 60))
        XCTAssertEqual(outcomes, [])
        XCTAssertFalse(events.contains(.microphoneDropped))

        mic.finishStop()
        await settle { !self.outcomes.isEmpty }
        XCTAssertEqual(inserter.copied, ["Hello."])
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.locked)])
    }

    /// back, and the mic still says nothing: it gets the same second and a
    /// half any stop gets, counted from your return, and then the take is
    /// lost out loud.
    func testAStopStillSilentAfterYouAreBackIsLost() async {
        let m = machine()
        mic.holdsStop = true
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { self.mic.isStopping }
        await pass(.seconds(60))

        m.systemResumed()
        await pass(.seconds(1))
        XCTAssertEqual(outcomes, [])
        await pass(.seconds(1))

        XCTAssertEqual(outcomes, [.recordingLost])
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        XCTAssertEqual(m.state, .idle)
    }

    /// a stop that throws has nothing to fall back on: lost, and said once
    /// you are back.
    func testAStopThatFailsUnderTheLockIsLostAndSaidWhenYouAreBack() async {
        let m = machine()
        mic.failsToStop = true
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }
        await pass(.seconds(1))

        XCTAssertEqual(outcomes, [.recordingLost])
        XCTAssertEqual(pills, [])
        m.systemResumed()
        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
    }

    /// keys only reach the app from a session someone is sitting at. a
    /// press is proof the mac is back even if the unlock never said so:
    /// what was held is said, and nothing after it is held.
    func testAPressIsProofTheMacIsBack() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(3))
        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }
        await pass(.seconds(1))

        engine.reply = .success("")
        m.keyDown()
        XCTAssertEqual(pills, [Self.copiedBeforeTheLock])
        await pass(.seconds(1))
        m.keyUp()
        await settle { self.pills.count == 2 }
        XCTAssertEqual(pills.last, Pill("heard nothing", 2.4))
    }

    // MARK: - helpers

    private static let copiedBeforeTheLock = Pill(
        "copied — what you said before the lock · ⌘V to paste",
        4
    )

    private var keepAwake: [Bool] {
        events.compactMap {
            if case let .keepAwake(awake) = $0 {
                return awake
            }
            return nil
        }
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

    private var archived: [Kept] {
        events.compactMap {
            if case let .archiveRecord(_, heard, inserted) = $0 {
                return Kept(heard: heard, inserted: inserted)
            }
            return nil
        }
    }

    private func hold(
        _ machine: UtteranceMachine,
        for duration: Duration
    ) async {
        machine.keyDown()
        await pass(duration)
        machine.keyUp()
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
