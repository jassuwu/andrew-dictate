import XCTest

/// the dictation path from key-down to outcome, driven through the machine's
/// own inputs with a fake mic, engine, inserter and clock. what is asserted
/// is what a person would notice: what was pasted, which pill, how the lamp
/// left, what was kept.
@MainActor
final class UtteranceMachineTests: XCTestCase {
    private var clock: FakeUtteranceClock!
    private var mic: FakeMic!
    private var engine: FakeEngine!
    private var inserter: FakeInserter!
    private var events: [UtteranceEvent] = []
    /// the coordinator's half of "is a pill up": shown by a pill, cleared by
    /// the next state change, or by a test saying its time ran out.
    private var pillShowing = false
    /// nil is the app refusing the press itself — a model still loading, a
    /// missing grant, no input device — for `refusal`'s reason.
    private var micForPress: FakeMic?
    private var refusal: PressRecord.Refusal = .modelNotReady

    override func setUp() async throws {
        clock = FakeUtteranceClock()
        mic = FakeMic(clock: clock)
        micForPress = mic
        refusal = .modelNotReady
        engine = FakeEngine()
        inserter = FakeInserter(clock: clock)
        events = []
        pillShowing = false
    }

    override func tearDown() async throws {
        // a held transcription, start or stop must not outlive its test.
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
            guard let self else {
                return .refused(.modelNotReady)
            }
            return self.micForPress.map { .ready($0) } ?? .refused(self.refusal)
        }
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
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.secureField)])
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
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.focusChanged)])
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
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.pasteboardUnavailable)])
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
        XCTAssertEqual(outcomes, [.heardNothing])
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
        XCTAssertEqual(outcomes, [.brushed])
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
        XCTAssertEqual(outcomes, [.brushed])
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
        XCTAssertEqual(outcomes, [.couldNotTranscribe])

        engine.reply = .success("the build failed")
        m.keyDown()
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(mic.starts, 1)
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(engine.heard, [mic.samples, mic.samples])
        XCTAssertEqual(inserter.inserted, ["The build failed."])
        XCTAssertEqual(completions, [.delivered])
        XCTAssertEqual(retryOffers, [true, false])
        // the replay is its own press, heard through no mic at all.
        XCTAssertEqual(outcomes, [.couldNotTranscribe, .delivered])
        XCTAssertEqual(presses.map(\.retry), [false, true])
        XCTAssertEqual(presses.last?.samples, 1_600)
        XCTAssertNil(presses.last?.mic)
        // the key's eventual release ends nothing: there is no recording.
        m.keyUp()
        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(presses.count, 2)
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
        XCTAssertEqual(outcomes, [.couldNotTranscribe, .delivered])
        XCTAssertEqual(presses.map(\.retry), [false, true])
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
        XCTAssertEqual(outcomes, [.cancelled])
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
        // the engine's late answer ends nothing a second time.
        XCTAssertEqual(outcomes, [.cancelled])
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
        XCTAssertEqual(outcomes, [.refused(.stillFinishing)])

        engine.release()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["First thought."])
        // two presses, two records: the refusal does not end the sentence
        // it was refused for.
        XCTAssertEqual(outcomes, [.refused(.stillFinishing), .delivered])
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
        // the hung one is over; the new take is still in flight.
        XCTAssertEqual(outcomes, [.droppedAsHung])
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
        XCTAssertEqual(outcomes, [.delivered])
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
        XCTAssertEqual(outcomes, [.refused(.modelNotReady)])
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
        // delivered, and the record says the ceiling ended it, not you.
        XCTAssertEqual(outcomes, [.delivered])
        XCTAssertEqual(presses.map(\.capped), [true])
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
        XCTAssertEqual(presses.map(\.capped), [true, false])
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

    // MARK: - a mic slow to answer

    /// the lamp is up before the mic has answered: a device slow to open
    /// must never make the press look dead. the chime waits for the mic.
    func testTheLampIsUpBeforeTheMicAnswers() async {
        let m = machine()
        mic.holdsStart = true

        m.keyDown()

        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(states, [.init(.recording, fast: false)])
        XCTAssertTrue(mic.isStarting)
        await pass(.milliseconds(200))
        XCTAssertEqual(chimes, [])

        mic.finishStart()
        await settle()
        XCTAssertEqual(chimes, [.start])
        XCTAssertEqual(m.state, .recording)
    }

    /// let go before the mic answered: the take still counts. it is stopped
    /// the moment it has started, and what it heard is pasted.
    func testALetGoBeforeTheMicAnsweredStillCounts() async {
        let m = machine()
        engine.reply = .success("quick one")
        mic.holdsStart = true

        m.keyDown()
        await pass(.milliseconds(400))
        m.keyUp()
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(m.state, .recording)

        mic.finishStart()
        await settle { self.inserter.inserted.count == 1 }

        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(inserter.inserted, ["Quick one."])
        XCTAssertEqual(outcomes, [.delivered])
        XCTAssertEqual(presses.first?.stages.keyUp, 400)
        // the take was over before the mic answered: a start chime after
        // the release would be noise.
        XCTAssertEqual(chimes, [.end])
    }

    /// esc while the mic is still opening throws the take away, and the
    /// mic's late answer records nothing.
    func testEscBeforeTheMicAnswersThrowsTheTakeAway() async {
        let m = machine()
        mic.holdsStart = true
        m.keyDown()

        XCTAssertTrue(m.escape())
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(mic.cancels, 1)

        mic.finishStart()
        m.keyUp()
        await pass(.milliseconds(200))

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(chimes, [])
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(pills, [])
        XCTAssertEqual(outcomes, [.cancelled])
    }

    /// a brush while the mic is still opening makes no sound, not even
    /// once the mic has answered.
    func testABrushBeforeTheMicAnswersMakesNoSound() async {
        let m = machine()
        mic.holdsStart = true
        m.keyDown()
        await pass(.milliseconds(50))

        m.keyCancelled()
        mic.finishStart()
        await pass(.milliseconds(200))

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(chimes, [])
        XCTAssertEqual(outcomes, [.brushed])
    }

    /// a mic that never answers ends the press within a moment and says so,
    /// and is dropped: the next press is handed a fresh one, and records.
    func testAMicThatNeverAnswersIsDroppedAndTheNextPressRecords() async {
        let m = machine()
        mic.holdsStart = true
        m.keyDown()

        await pass(.milliseconds(1_400))
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(pills, [])

        await pass(.milliseconds(100))
        await settle { !self.pills.isEmpty }
        XCTAssertEqual(pills, [Pill("microphone isn't responding", 2)])
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(chimes, [])
        XCTAssertEqual(outcomes, [.micNotResponding])

        let fresh = FakeMic(clock: clock)
        micForPress = fresh
        pillShowing = false
        engine.reply = .success("second try")
        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["Second try."])
        XCTAssertEqual(outcomes, [.micNotResponding, .delivered])

        // the wedged mic answering at last changes nothing.
        mic.finishStart()
        await settle()
        XCTAssertEqual(mic.stops, 0)
        XCTAssertEqual(outcomes, [.micNotResponding, .delivered])
    }

    /// a stop that never comes back loses the take, says so, and drops the
    /// mic; its late answer goes nowhere.
    func testARecordingThatNeverStopsIsLostAndDropped() async {
        let m = machine()
        mic.holdsStop = true
        m.keyDown()
        await pass(.seconds(1))
        m.keyUp()
        XCTAssertTrue(mic.isStopping)
        XCTAssertEqual(m.state, .recording)

        await pass(.milliseconds(1_500))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(outcomes, [.recordingLost])

        mic.finishStop()
        await settle()
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(outcomes, [.recordingLost])
    }

    /// pressing again while the last take's mic is still stopping: that
    /// sentence is on its way, and the key says why it is deaf.
    func testAPressWhileTheMicIsStillStoppingIsRefusedOutLoud() async {
        let m = machine()
        engine.reply = .success("first thought")
        mic.holdsStop = true
        await hold(m, for: .seconds(1))

        m.keyDown()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("still finishing the last one", 1.4)])
        XCTAssertEqual(outcomes, [.refused(.stillFinishing)])
        XCTAssertEqual(mic.starts, 1)

        mic.finishStop()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["First thought."])
        XCTAssertEqual(outcomes, [.refused(.stillFinishing), .delivered])
    }

    /// a take thrown away while its mic was still opening: if that mic
    /// never answers it is dropped all the same, so the next press opens a
    /// fresh one instead of queueing behind it. no pill: that press is over.
    func testAMicThatNeverAnswersIsDroppedEvenAfterEsc() async {
        let m = machine()
        mic.holdsStart = true
        m.keyDown()
        XCTAssertTrue(m.escape())

        await pass(.milliseconds(1_400))
        XCTAssertFalse(events.contains(.microphoneDropped))
        await pass(.milliseconds(100))

        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(pills, [])
        XCTAssertEqual(outcomes, [.cancelled])
    }

    /// one that refuses after the take was thrown away is dropped too.
    func testAMicThatRefusesAfterEscIsDropped() async {
        let m = machine()
        mic.holdsStart = true
        mic.failsToStart = true
        m.keyDown()
        XCTAssertTrue(m.escape())

        mic.finishStart()
        await settle()

        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(pills, [])
        XCTAssertEqual(outcomes, [.cancelled])
    }

    // MARK: - the mac underneath

    /// only you throw an utterance away: sleep or the lock ends the take
    /// and keeps it, copied rather than pasted. the rest of that path is
    /// `UtteranceMachineInterruptionTests`.
    func testSleepOrTheLockMidRecordingKeepsIt() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))

        m.captureInterrupted(.systemPaused)
        await settle { !self.outcomes.isEmpty }

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(mic.cancels, 0)
        XCTAssertEqual(engine.heard, [mic.samples])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(inserter.copied, ["Hello."])
        XCTAssertEqual(completions, [.leftOnPasteboard])
        XCTAssertEqual(outcomes, [.leftOnPasteboard(.locked)])
    }

    /// the mic changing mid-sentence ends the take but keeps it: what was
    /// heard up to the change is pasted, and only then does a pill say why
    /// the take ended without you.
    func testAMicThatChangesMidRecordingPastesWhatItHad() async {
        let m = machine()
        engine.reply = .success("half a thought")
        m.doubleTapped()
        await settle { !self.pills.isEmpty }
        await pass(.seconds(2))

        m.captureInterrupted(.deviceChanged)

        XCTAssertEqual(lockFlags, [true, false])
        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(mic.cancels, 0)
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["Half a thought."])
        XCTAssertEqual(engine.heard, [mic.samples])
        XCTAssertEqual(
            pills.last,
            Pill("the mic changed — pasted what i had.", 2.4)
        )
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(outcomes, [.delivered])
        XCTAssertEqual(presses.map(\.micChanged), [true])
        XCTAssertEqual(presses.first?.stages.keyUp, 2_000)

        // the tap that would have ended the lock ends nothing more.
        m.keyUp()
        await settle()
        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(presses.count, 1)
    }

    /// nothing heard before the change: it ends as any silence does, and
    /// the engine is not asked about it.
    func testAMicThatChangesBeforeAnythingWasHeardSaysHeardNothing() async {
        let m = machine()
        mic.samples = []
        m.keyDown()
        await pass(.seconds(1))

        m.captureInterrupted(.deviceChanged)
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("heard nothing", 2.4)])
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(engine.heard, [])
        XCTAssertFalse(events.contains(.retryOffered(true)))
        XCTAssertEqual(outcomes, [.heardNothing])
        XCTAssertEqual(presses.map(\.micChanged), [true])
    }

    /// a mic that changes while it is still opening: the take ends the
    /// moment it answers, with whatever it had.
    func testAMicThatChangesWhileOpeningEndsTheTakeWhenItAnswers() async {
        let m = machine()
        mic.holdsStart = true
        mic.samples = []
        m.keyDown()

        m.captureInterrupted(.deviceChanged)
        XCTAssertEqual(m.state, .recording)
        mic.finishStart()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(pills, [Pill("heard nothing", 2.4)])
        XCTAssertEqual(outcomes, [.heardNothing])
    }

    /// the take after a mic change is not flagged because the last one was.
    func testTheTakeAfterAMicChangeEndsQuietly() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))
        m.captureInterrupted(.deviceChanged)
        await settle { self.inserter.inserted.count == 1 }
        let pillsAfterTheChange = pills.count
        await pass(.milliseconds(400))

        await hold(m, for: .seconds(1))
        await settle { self.inserter.inserted.count == 2 }

        XCTAssertEqual(pills.count, pillsAfterTheChange)
        XCTAssertEqual(presses.map(\.micChanged), [true, false])
    }

    /// once the words are with the engine, the mic going away costs nothing.
    func testAnInterruptionWhileTranscribingChangesNothing() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("still here")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.captureInterrupted(.deviceChanged)
        XCTAssertEqual(m.state, .transcribing)

        engine.release()
        await settle { self.inserter.inserted.count == 1 }
        XCTAssertEqual(inserter.inserted, ["Still here."])
        XCTAssertEqual(outcomes, [.delivered])
    }

    // MARK: - the app pulling the rug

    /// a setting that rebuilds the mic cannot do it under a live take.
    func testASettingThatRebuildsTheMicAbandonsTheTake() async {
        let m = machine()
        m.keyDown()
        await pass(.seconds(1))

        m.abandonRecording()
        await settle()

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(mic.cancels, 1)
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(outcomes, [.abandoned])
    }

    /// the speech model being taken away takes the sentence in flight with
    /// it, and the engine's late answer goes nowhere.
    func testTakingTheSpeechModelAwayAbandonsWhatIsInFlight() async {
        let m = machine()
        engine.holds = true
        engine.reply = .success("too late")
        await hold(m, for: .seconds(1))
        await settle { self.engine.isWaiting }

        m.abandon()
        engine.release()
        await settle()

        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(outcomes, [.abandoned])
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
        // which mic refused is the whole point of the record.
        XCTAssertEqual(outcomes, [.couldNotStartRecording])
        XCTAssertEqual(presses.first?.mic, MicDescription(name: "AirPods Pro", transport: .bluetooth))
    }

    /// no input device at all is not a mic that refused: the press says
    /// so, and the next one looks for a mic again.
    func testNoMicrophoneAtAllSaysSo() async {
        let m = machine()
        mic.hasNoDevice = true

        m.keyDown()
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("no microphone available", 1.6)])
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(outcomes, [.refused(.noMicrophone)])
    }

    /// they spoke and there is nothing to show for it, so it says so, and
    /// the next press opens a fresh mic.
    func testARecordingThatWillNotStopSaysItWasLost() async {
        let m = machine()
        mic.failsToStop = true

        await hold(m, for: .seconds(1))
        await settle { !self.pills.isEmpty }

        XCTAssertEqual(pills, [Pill("recording was lost", 1.6)])
        // a mic that would not stop is not trusted with the next take.
        XCTAssertTrue(events.contains(.microphoneDropped))
        XCTAssertEqual(states.last, .init(.idle, fast: true))
        XCTAssertEqual(chimes, [.start])
        XCTAssertEqual(engine.heard, [])
        XCTAssertEqual(completions, [])
        XCTAssertEqual(outcomes, [.recordingLost])
        XCTAssertEqual(presses.first?.stages.keyUp, 1_000)
    }

    /// a press the app answered itself — a model still loading, a missing
    /// grant, no input device — leaves the machine where it was.
    func testAPressTheAppAnsweredLeavesOnlyItsRecord() async {
        let m = machine()
        micForPress = nil

        for why in [
            PressRecord.Refusal.modelNotReady,
            .microphonePermissionOff,
            .noMicrophone,
        ] {
            refusal = why
            m.keyDown()
        }
        await settle()

        XCTAssertEqual(outcomes, [
            .refused(.modelNotReady),
            .refused(.microphonePermissionOff),
            .refused(.noMicrophone),
        ])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(m.state, .idle)
    }

    /// a meeting owns the mic: the app refuses before the machine is asked
    /// for anything, and the press still leaves its record.
    func testAPressRefusedForAMeetingLeavesItsRecordAndNothingElse() async {
        let m = machine()

        m.refusePress(.meetingRunning)
        await settle()

        XCTAssertEqual(outcomes, [.refused(.meetingRunning)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(mic.starts, 0)
        XCTAssertEqual(presses.first?.engine, "v2")
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

    /// key-up is when the finger lifted, not when the event reached us: a
    /// busy main thread must not hide inside the published latency.
    func testKeyUpIsWhenTheKeyWasReleasedNotWhenWeHeard() async {
        let m = machine()
        engine.reply = .success("on time")

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp(eventAge: .milliseconds(30))
        await settle { !self.presses.isEmpty }

        XCTAssertEqual(presses.first?.stages.keyUp, 970)
        XCTAssertEqual(presses.first?.stages.samplesReady, 1_000)
    }

    /// an event older than the press itself is a clock that disagrees, and
    /// a key cannot come up before it went down.
    func testKeyUpNeverLandsBeforeKeyDown() async {
        let m = machine()
        engine.reply = .success("on time")

        m.keyDown()
        await pass(.seconds(1))
        m.keyUp(eventAge: .seconds(5))
        await settle { !self.presses.isEmpty }

        XCTAssertEqual(presses.first?.stages.keyUp, 0)
    }

    /// a stall of the main thread mid-press is noted on that press: the
    /// longest one, since that is the one that made it feel dead.
    func testTheLongestMainThreadStallIsNotedOnThePressInFlight() async {
        let m = machine()
        engine.reply = .success("still here")

        m.mainStalled(for: .milliseconds(900))
        m.keyDown()
        m.mainStalled(for: .milliseconds(812))
        m.mainStalled(for: .milliseconds(600))
        await pass(.seconds(1))
        m.keyUp()
        await settle { !self.presses.isEmpty }

        XCTAssertEqual(presses.map(\.mainStallMs), [812])
    }

    /// the record is what gets sent to jass, so no field of it may carry a
    /// word of what was said — not the engine's words, not the pasted ones.
    func testNoRecordCarriesAWordOfWhatWasSaid() async throws {
        let m = machine()
        engine.reply = .success("zanzibar marmalade")
        await hold(m, for: .seconds(1))
        await settle { self.presses.count == 1 }
        await pass(.milliseconds(400))

        inserter.result = .leftOnPasteboard(.focusChanged)
        await hold(m, for: .seconds(1))
        await settle { self.presses.count == 2 }

        XCTAssertEqual(inserter.inserted, ["Zanzibar marmalade.", "Zanzibar marmalade."])
        XCTAssertEqual(presses.map(\.words), [2, 2])
        for record in presses {
            let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            let fields = String(reflecting: record)
            let line = record.line()
            for said in ["zanzibar", "marmalade"] {
                XCTAssertFalse(json.localizedCaseInsensitiveContains(said), json)
                XCTAssertFalse(fields.localizedCaseInsensitiveContains(said), fields)
                XCTAssertFalse(line.localizedCaseInsensitiveContains(said), line)
            }
        }
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

struct Pill: Equatable, CustomStringConvertible {
    let message: String
    let duration: TimeInterval

    init(_ message: String, _ duration: TimeInterval) {
        self.message = message
        self.duration = duration
    }

    var description: String { "\(message) (\(duration)s)" }
}

struct StateChange: Equatable {
    let state: UtteranceMachine.State
    let fast: Bool

    init(_ state: UtteranceMachine.State, fast: Bool) {
        self.state = state
        self.fast = fast
    }
}

struct Kept: Equatable {
    let heard: String
    let inserted: String
}

// MARK: - fakes

private struct MicFailure: Error {}

@MainActor
final class FakeMic: MicCapture {
    var samples: [Float] = (0..<1_600).map { Float($0 % 7) * 0.01 }
    let deviceDescription: MicDescription? = MicDescription(
        name: "AirPods Pro",
        transport: .bluetooth
    )
    var failsToStart = false
    /// the mac has no input device at all to open.
    var hasNoDevice = false
    var failsToStop = false
    /// while set, start waits for `finishStart()`: a device slow to open,
    /// or, never finished, one that never does.
    var holdsStart = false
    /// the same for stop, finished by `finishStop()`.
    var holdsStop = false
    /// asked to start, whether or not it ever answered.
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private var heldStart: CheckedContinuation<Void, Never>?
    private var heldStop: CheckedContinuation<Void, Never>?
    private let clock: FakeUtteranceClock

    init(clock: FakeUtteranceClock) {
        self.clock = clock
    }

    var isStarting: Bool {
        heldStart != nil
    }

    var isStopping: Bool {
        heldStop != nil
    }

    /// the first buffer lands the moment it answers: a fake mic has nothing
    /// to warm up.
    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {
        starts += 1
        if holdsStart {
            await withCheckedContinuation { heldStart = $0 }
        }
        if hasNoDevice {
            throw MicCaptureError.noInputDevice
        }
        if failsToStart {
            throw MicFailure()
        }
        onFirstBuffer(clock.now)
    }

    func stop() async throws -> [Float] {
        if holdsStop {
            await withCheckedContinuation { heldStop = $0 }
        }
        if failsToStop {
            throw MicFailure()
        }
        stops += 1
        return samples
    }

    func cancel() {
        cancels += 1
    }

    func finishStart() {
        let held = heldStart
        heldStart = nil
        held?.resume()
    }

    func finishStop() {
        let held = heldStop
        heldStop = nil
        held?.resume()
    }

    /// a test must not leave a start or a stop hanging behind it.
    func release() {
        finishStart()
        finishStop()
    }
}

private struct EngineFailure: Error {}

/// answers with `reply`, or — while `holds` is set — waits for the test to
/// `release()` it, the way a slow or hung engine would.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
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
struct FakeAnchor: InsertionAnchor {
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
final class FakeInserter: Inserter {
    var anchor: FakeAnchor? = FakeAnchor(
        targetBundleIdentifier: "com.apple.TextEdit"
    )
    var result: PasteResult = .pasted
    private(set) var inserted: [String] = []
    private let clock: FakeUtteranceClock

    init(clock: FakeUtteranceClock) {
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

    /// what was left on the clipboard without a paste being tried.
    private(set) var copied: [String] = []

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
