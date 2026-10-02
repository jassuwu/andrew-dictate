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

    // MARK: - helpers

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
