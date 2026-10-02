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
        machine.engineVersion = { "v2" }
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

    // MARK: - where the words land

    /// a second dictation into a running sentence gets no capital and a
    /// space to stand apart from it — and the space is a delivery detail,
    /// not part of what is kept.
    func testDictatingIntoARunningSentenceJoinsIt() async {
        let m = machine()
        inserter.anchor = FakeAnchor(
            targetBundleIdentifier: "com.apple.TextEdit",
            before: "the build failed because"
        )
        engine.reply = .success("the cache was cold")

        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(inserter.inserted, [" the cache was cold."])
        XCTAssertEqual(archived, [.init(heard: "the cache was cold", inserted: "the cache was cold.")])
    }

    /// the fixer's field is a correction, not a sentence: the dictionary
    /// runs, full cleanup does not.
    func testDictatingIntoOurOwnWindowSkipsFullCleanup() async {
        let m = machine()
        inserter.anchor = FakeAnchor(targetBundleIdentifier: "gg.jass.dictate.dev")
        engine.reply = .success("cache")

        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(inserter.inserted, ["cache"])
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

    // MARK: - esc

    /// only you throw an utterance away: the mic closes, nothing reaches
    /// the engine, and the timeline says cancelled.
    func testEscWhileRecordingThrowsTheUtteranceAway() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))

        XCTAssertTrue(m.escape())

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(completions, [.cancelled])
        m.keyUp()
        await settle()
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(pills, [])
    }

    /// the sentence on its way to the page is dropped, and the engine's
    /// late answer goes nowhere.
    func testEscWhileTranscribingDropsTheSentence() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("never mind")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        XCTAssertTrue(m.escape())
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(completions, [.cancelled])

        engine.release()
        await settle()
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(pills, [])
        XCTAssertEqual(m.state, .idle)
    }

    /// with nothing to throw away, esc belongs to whatever app is in front.
    func testEscWithNothingInFlightIsNotOurs() {
        let m = machine()
        XCTAssertFalse(m.escape())
        m.enginePreparing()
        XCTAssertFalse(m.escape())
        XCTAssertEqual(events, [.state(.prewarming, fastDismiss: false)])
    }

    // MARK: - pressing again while it writes

    /// you talk in bursts and press again just after letting go. the
    /// sentence in flight is worth more than the new one, and the key says
    /// why it is deaf.
    func testAPressRightAfterLettingGoIsRefusedOutLoud() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("first thought")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.keyDown()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("still finishing the last one", 1.4)])
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(mic.starts, 1)

        engine.release()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["First thought."])
    }

    /// long enough to be a hang: the key must not be wedged, so the old
    /// sentence goes and a new take starts.
    func testAPressAfterAHungTranscriptionDropsItAndRecords() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("first thought")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }
        await pass(.seconds(3))

        m.keyDown()

        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(mic.starts, 2)
        engine.release()
        await settle()
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(pills, [])
        XCTAssertEqual(m.state, .recording)
    }

    // MARK: - locked recording

    /// nothing to hold means nothing to feel, so the lamp carries the lock
    /// and a pill says how to end it. a tap ends it like a release.
    func testADoubleTapLocksTheRecordingAndATapEndsIt() async {
        let m = machine()
        engine.reply = .success("hands free")

        m.doubleTapped()
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(lockFlags, [true])
        await settle { !self.pills.isEmpty }
        XCTAssertEqual(pills, [Pill("locked — tap to end", 1.6)])

        await pass(.seconds(10))
        m.keyUp()
        XCTAssertEqual(lockFlags, [true, false])
        XCTAssertEqual(m.state, .transcribing)
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["Hands free."])
        XCTAssertEqual(completions, [.delivered])
    }

    /// a lamp that says "locked" over nothing is a lie.
    func testALockThatNeverStartedClaimsNothing() async {
        let m = machine()
        micForPress = nil

        m.doubleTapped()
        await settle()

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(lockFlags, [])
        XCTAssertEqual(pills, [])
    }

    func testADoubleTapMidRecordingIsNotASecondRecording() async {
        let m = machine()
        m.keyDown()

        m.doubleTapped()
        await settle()

        XCTAssertEqual(mic.starts, 1)
        XCTAssertEqual(lockFlags, [])
        XCTAssertEqual(pills, [])
    }

    // MARK: - the capture ceiling

    func testThirtySecondsBeforeTheCeilingItSaysSo() async {
        let m = machine()
        m.keyDown()

        m.capApproaching()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("thirty seconds left", 2)])
        XCTAssertEqual(m.state, .recording)
    }

    /// the ceiling ends the take and keeps it: what was heard is pasted,
    /// and only then does a pill say why the take ended without you.
    func testTheCeilingPastesWhatItHadAndSaysWhy() async {
        let m = machine()
        engine.reply = .success("a very long thought")
        m.doubleTapped()
        await pass(.seconds(300))

        XCTAssertTrue(m.capReached())
        XCTAssertEqual(lockFlags, [true, false])
        XCTAssertEqual(m.state, .transcribing)
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(inserter.inserted, ["A very long thought."])
        XCTAssertEqual(completions, [.delivered])
        XCTAssertEqual(
            pills.last,
            Pill("five minutes — that's the cap. pasted what i had.", 2.4)
        )
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: false))
    }

    /// the next take is not capped because the last one was.
    func testTheTakeAfterTheCeilingEndsQuietly() async {
        let m = machine()
        m.keyDown()
        m.capReached()
        await settle { self.inserter.inserted.count == 1 }
        let pillsAfterTheCap = pills.count

        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 2 }

        XCTAssertEqual(pills.count, pillsAfterTheCap)
    }

    /// a hop that lands after the take is over is about a finger that has
    /// already lifted.
    func testTheCeilingOutsideARecordingIsNotNews() async {
        let m = machine()

        XCTAssertFalse(m.capReached())
        m.capApproaching()
        await settle()

        XCTAssertEqual(events, [])
    }

    // MARK: - the mac underneath

    /// today's behaviour, which ticket 06 reverses: sleep or the lock ends
    /// the take and throws it away, saying nothing — the pill would be gone
    /// before the screen came back.
    func testSleepOrTheLockMidRecordingDiscardsItSilently() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))

        m.captureInterrupted(.systemPaused)
        await settle()

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(pills, [])
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(completions, [])
    }

    /// a microphone that vanished mid-sentence is a loss, and losses speak.
    func testAMicThatChangesMidRecordingSaysSayThatAgain() async {
        let m = machine()
        m.doubleTapped()
        await settle { !self.pills.isEmpty }

        m.captureInterrupted(.deviceChanged)
        await settle { self.pills.count == 2 }

        XCTAssertEqual(pills.last, Pill("the microphone changed — say that again", 2))
        XCTAssertEqual(lockFlags, [true, false])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(engine.heard, [])
    }

    /// once the words are with the engine, the mic going away costs nothing.
    func testAnInterruptionWhileTranscribingChangesNothing() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("still here")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.captureInterrupted(.systemPaused)
        XCTAssertEqual(m.state, .transcribing)

        engine.release()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["Still here."])
    }

    // MARK: - when the mic fails

    /// the device may have been yanked between the check and the tap: the
    /// recorder is dropped so the next press builds a fresh one.
    func testAMicThatWillNotStartIsDroppedAndSaysSo() async {
        let m = machine()
        mic.failsToStart = true

        m.keyDown()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("couldn't start recording", 1.6)])
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(m.state, .idle)
        await pass(.milliseconds(200))
        XCTAssertEqual(chimes, [])
    }

    /// they spoke and there is nothing to show for it, so it says so.
    func testARecordingThatWillNotStopSaysItWasLost() async {
        let m = machine()
        mic.failsToStop = true

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(chimes, [.start])
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(completions, [])
    }

    /// a press the app answered itself — a model still loading, a missing
    /// grant, no input device — leaves the machine where it was.
    func testAPressTheAppAnsweredLeavesNoTrace() async {
        let m = machine()
        micForPress = nil

        m.keyDown()
        await settle()

        XCTAssertEqual(events, [])
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - the press log

    /// every press leaves exactly one record, and a delivered one carries
    /// the whole path: the mic, what it heard, and when each stage landed.
    func testADeliveredPressLeavesOneRecordOfTheWholePath() async {
        let m = machine()
        engine.reply = .success("the build failed")

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        await settle { !self.presses.isEmpty }
        await pass(.milliseconds(400))

        XCTAssertEqual(presses.count, 1)
        let press = presses[0]
        XCTAssertEqual(press.outcome, .delivered)
        XCTAssertEqual(press.mic, MicDescription(name: "AirPods Pro", transport: .bluetooth))
        XCTAssertEqual(press.samples, 1_600)
        XCTAssertEqual(press.peak ?? 0, 0.06, accuracy: 0.000_1)
        XCTAssertEqual(press.words, 3)
        XCTAssertEqual(press.engine, "v2")
        XCTAssertEqual(press.stages, PressRecord.Stages(
            firstBuffer: 0,
            keyUp: 1_000,
            samplesReady: 1_000,
            transcriptReady: 1_000,
            cleaned: 1_000,
            pastePosted: 1_000,
            pasteCompleted: 1_000,
            ended: 1_000
        ))
        XCTAssertFalse(press.capped)
        XCTAssertFalse(press.retry)
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

    private var lockFlags: [Bool] {
        events.compactMap {
            if case let .locked(locked) = $0 {
                return locked
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
    let deviceDescription: MicDescription? = MicDescription(
        name: "AirPods Pro",
        transport: .bluetooth
    )
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
