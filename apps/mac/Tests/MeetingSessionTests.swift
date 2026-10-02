import XCTest

final class MeetingSessionTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetingSession(quietNudgeAfter: .seconds(3_600))
    }

    // MARK: - starting

    func testNothingStartsARecordingExceptTheUser() {
        var session = session()
        XCTAssertEqual(session.state, .idle)

        // There is deliberately no event for "a meeting app took the
        // microphone" — ADR 0023 does not observe the mic at all.
        session.start()
        XCTAssertEqual(session.state, .provingItCanHear)
    }

    func testStartingTwiceIsNotAnError() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.start()

        XCTAssertEqual(session.state, .recording)
    }

    // MARK: - the probe (ADR 0021)

    func testHearingTheProbeMeansRecording() {
        var session = session()
        session.start()
        session.heardTheProbe()

        XCTAssertEqual(session.state, .recording)
    }

    func testSilenceThroughTheProbeStopsBeforeAnythingIsKept() {
        var session = session()
        session.start()
        session.neverHeardTheProbe()

        XCTAssertEqual(session.state, .cannotHear)
        XCTAssertNil(session.finish(at: .seconds(10)))
    }

    /// No output to play the start sound on: the tap was never asked, so
    /// its silence proves nothing. "Could not check" is not "cannot hear" —
    /// the meeting records, and what it captures is kept.
    func testAProbeThatCouldNotPlayIsNotAProbeThatWentUnheard() {
        var session = session()
        session.start()
        session.couldNotPlayTheProbe()

        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.finish(at: .seconds(30))?.isComplete, true)
    }

    // MARK: - the tap dying mid-meeting

    func testADeadTapIsRebuiltAndTheGapIsRemembered() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(600))
        XCTAssertEqual(session.state, .rebuilding)

        session.tapRecovered(at: .seconds(700))
        XCTAssertEqual(session.state, .recording)

        let recording = session.finish(at: .seconds(900))
        XCTAssertEqual(recording?.gaps.count, 1)
        XCTAssertEqual(recording?.gaps.first?.duration, .seconds(100))
    }

    /// SPEC §4, extended: a recording with holes in it must not be handed back
    /// looking whole.
    func testARecordingWithGapsSaysSo() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))
        session.tapRecovered(at: .seconds(120))

        XCTAssertEqual(session.finish(at: .seconds(200))?.isComplete, false)
    }

    func testARecordingThatNeverBrokeIsComplete() {
        var session = session()
        session.start()
        session.heardTheProbe()

        XCTAssertEqual(session.finish(at: .seconds(200))?.isComplete, true)
    }

    /// A tap that cannot be rebuilt is a problem, not the end: the meeting
    /// goes on, your side with it, and the gap stays open until the tap is
    /// back — or runs to the end of a meeting stopped before it was.
    func testARebuildThatFailsIsAProblemTheMeetingRecordsThrough() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))
        session.problemBegan(.cannotHearTheCall)

        XCTAssertEqual(session.state, .rebuilding)
        XCTAssertEqual(session.problem, .cannotHearTheCall)
        XCTAssertEqual(session.dictationRequest(), .refuseAndSayWhy)
        let recording = session.finish(at: .seconds(70))
        XCTAssertEqual(recording?.gaps, [.init(began: .seconds(60), ended: .seconds(70))])
        XCTAssertEqual(recording?.isComplete, false)
        XCTAssertNil(session.problem, "a meeting that has ended has no problem")
    }

    func testAProblemClearsWhenItIsOver() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))
        session.problemBegan(.cannotHearTheCall)

        session.tapRecovered(at: .seconds(90))
        session.problemCleared(.cannotHearTheCall)

        XCTAssertNil(session.problem)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(
            session.finish(at: .seconds(100))?.gaps,
            [.init(began: .seconds(60), ended: .seconds(90))])
    }

    /// A problem belongs to a meeting that is running: none before the tap
    /// has been heard, none once it has stopped.
    func testOnlyARunningMeetingHasAProblem() {
        var session = session()
        session.problemBegan(.cannotHearTheCall)
        XCTAssertNil(session.problem)

        session.start()
        session.problemBegan(.cannotHearTheCall)
        XCTAssertNil(session.problem)

        session.heardTheProbe()
        session.problemBegan(.cannotHearTheCall)
        XCTAssertEqual(session.problem, .cannotHearTheCall)
    }

    /// The mic going silent and the disk filling are two things wrong at
    /// once: both stand, the worse first, and each clears on its own.
    func testTwoProblemsStandAtOnceAndClearOneAtATime() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.problemBegan(.diskNearlyFull)
        session.problemBegan(.cannotHearYourMic("MacBook Pro Microphone"))

        XCTAssertEqual(session.problems, [
            .cannotHearYourMic("MacBook Pro Microphone"), .diskNearlyFull,
        ])
        XCTAssertEqual(session.problem, .cannotHearYourMic("MacBook Pro Microphone"))

        session.problemCleared(.cannotHearYourMic)
        XCTAssertEqual(session.problems, [.diskNearlyFull])

        session.problemCleared(.diskNearlyFull)
        XCTAssertEqual(session.problems, [])
        XCTAssertNil(session.problem)
    }

    /// One of each kind: the call unheard is said one way while your side
    /// is still recorded and another once it is not, and the second
    /// wording takes the first's place rather than standing beside it.
    func testAProblemOfAKindAlreadyStandingTakesItsPlace() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))
        session.problemBegan(.cannotHearTheCall)
        session.problemBegan(.cannotHearAnything)

        XCTAssertEqual(session.problems, [.cannotHearAnything])
        session.problemCleared(.cannotHearTheCall)
        XCTAssertEqual(session.problems, [])
    }

    // MARK: - dictation is blocked, and says so

    func testDictationIsRefusedWhileRecordingRatherThanIgnored() {
        var session = session()
        session.start()
        session.heardTheProbe()

        XCTAssertEqual(session.dictationRequest(), .refuseAndSayWhy)
    }

    func testDictationWorksNormallyWhenNoMeetingIsRunning() {
        var session = session()
        XCTAssertEqual(session.dictationRequest(), .allow)

        session.start()
        session.heardTheProbe()
        _ = session.finish(at: .seconds(10))
        XCTAssertEqual(session.dictationRequest(), .allow)
    }

    /// A rebuild is still a live meeting. Letting dictation through here would
    /// make the hotkey work intermittently for reasons nobody could see.
    func testDictationIsAlsoRefusedWhileRebuilding() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))

        XCTAssertEqual(session.dictationRequest(), .refuseAndSayWhy)
    }

    // MARK: - you forgot to stop it

    func testAQuietHourAsksRatherThanStopping() {
        var session = session()
        session.start()
        session.heardTheProbe()

        XCTAssertFalse(session.shouldNudge(at: .seconds(3_599)))
        XCTAssertTrue(session.shouldNudge(at: .seconds(3_601)))
        XCTAssertEqual(
            session.state, .recording,
            "a nudge must never stop a meeting on its own"
        )
    }

    func testTheQuietTimerRestartsWheneverSomeoneSpeaks() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.heardAudio(at: .seconds(3_000))

        XCTAssertFalse(session.shouldNudge(at: .seconds(6_000)))
        XCTAssertTrue(session.shouldNudge(at: .seconds(6_700)))
    }

    /// A rebuild is the app proving the tap to itself with its own start
    /// sound. It is not the room speaking, so it must not buy the meeting
    /// another hour of silence.
    func testARecoveredTapIsNotSomebodySpeaking() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(600))
        session.tapRecovered(at: .seconds(700))

        XCTAssertTrue(session.shouldNudge(at: .seconds(3_601)))
    }

    func testAnAnsweredNudgeStopsAskingUntilItGoesQuietAgain() {
        var session = session()
        session.start()
        session.heardTheProbe()
        XCTAssertTrue(session.shouldNudge(at: .seconds(3_601)))

        session.keepGoing(at: .seconds(3_610))
        XCTAssertFalse(session.shouldNudge(at: .seconds(3_620)))
        XCTAssertTrue(session.shouldNudge(at: .seconds(7_300)))
    }
}
