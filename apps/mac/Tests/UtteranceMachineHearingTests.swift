import XCTest

/// the press and the hearing are two signals. the key brings the lamp up
/// warming; only the mic's first audio lights it and plays the chime, and a
/// mic that answers but sends nothing ends the press naming it.
///
/// driven with a mic whose first audio the test hands over, where
/// `UtteranceMachineTests`' mic is heard the moment it answers.
@MainActor
final class UtteranceMachineHearingTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var mic: CuedMic!
    private var engine: FakeEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []
    /// the coordinator's half of "is a pill up": shown by a pill, cleared by
    /// the next state change.
    private var pillShowing = false
    private var micForPress: CuedMic?

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = CuedMic(clock: clock)
        micForPress = mic
        engine = FakeEngine()
        inserter = FakeInserter(clock: clock)
        events = []
        pillShowing = false
    }

    override func tearDown() async throws {
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
        machine.microphoneForPress = { [weak self] in
            guard let mic = self?.micForPress else {
                return .refused(.modelNotReady)
            }
            return .ready(mic)
        }
        machine.isPillShowing = { [weak self] in self?.pillShowing ?? false }
        machine.engineVersion = { "v2" }
        return machine
    }

    // MARK: - the chime

    /// the key brings no sound of its own: the chime is the mic's first
    /// audio, however long after the press it lands.
    func testTheStartChimeWaitsForTheMicsFirstAudio() async {
        let m = machine()

        m.keyDown()
        await pass(.milliseconds(300))
        XCTAssertEqual(mic.starts, 1)
        XCTAssertEqual(chimes, [])

        mic.hear()
        XCTAssertEqual(chimes, [.start])
    }

    /// a mic heard at once still waits out the brush: the chime comes 120
    /// ms after the press, not with the first audio.
    func testAMicHeardAtOnceStillChimesOnlyOnceTheKeyIsHeld() async {
        let m = machine()

        m.keyDown()
        await pass(.milliseconds(30))
        mic.hear()
        await pass(.milliseconds(60))
        XCTAssertEqual(chimes, [])

        await pass(.milliseconds(30))
        XCTAssertEqual(chimes, [.start])
    }

    /// a brush of fn makes no sound, even with the mic already hearing it.
    func testABrushTheMicHeardMakesNoSound() async {
        let m = machine()

        m.keyDown()
        await pass(.milliseconds(30))
        mic.hear()
        await pass(.milliseconds(50))
        m.keyCancelled()
        await pass(.milliseconds(200))

        XCTAssertEqual(chimes, [])
        XCTAssertEqual(outcomes, [.brushed])
    }

    /// let go before the chime was due: the take is over, and its start
    /// chime would land after its end.
    func testAReleaseBeforeTheChimeWasDueSilencesIt() async {
        let m = machine()
        engine.reply = .success("quick")

        m.keyDown()
        await pass(.milliseconds(30))
        mic.hear()
        await pass(.milliseconds(50))
        m.keyUp()
        await pass(.milliseconds(200))

        XCTAssertFalse(chimes.contains(.start))
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

// MARK: - a mic heard on cue

/// answers its start at once, and is heard only when the test says so — or
/// never: a mic that opened and sends nothing, the way one the phone took
/// mid-call or a driver that wedged can.
@MainActor
final class CuedMic: MicCapture {
    /// a tenth of a second of speech at 16 kHz, peak 0.06.
    var samples: [Float] = (0..<1_600).map { Float($0 % 7) * 0.01 }
    var deviceDescription: MicDescription? = MicDescription(
        name: "AirPods Pro",
        transport: .bluetooth
    )
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private var firstBuffer: (@MainActor @Sendable (ContinuousClock.Instant) -> Void)?
    private let clock: FakeUtteranceClock

    init(clock: FakeUtteranceClock) {
        self.clock = clock
    }

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {
        starts += 1
        firstBuffer = onFirstBuffer
    }

    /// its first audio lands now. once: a mic is heard for the first time
    /// only once a take.
    func hear() {
        let callback = firstBuffer
        firstBuffer = nil
        callback?(clock.now)
    }

    func stop() async throws -> [Float] {
        stops += 1
        firstBuffer = nil
        return samples
    }

    func cancel() {
        cancels += 1
        firstBuffer = nil
    }
}
