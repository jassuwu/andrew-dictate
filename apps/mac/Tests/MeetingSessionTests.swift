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

    func testARebuildThatFailsStopsPretendingToRecord() {
        var session = session()
        session.start()
        session.heardTheProbe()
        session.tapWentSilent(at: .seconds(60))
        session.rebuildFailed()

        XCTAssertEqual(session.state, .cannotHear)
        // What was captured before it broke is still worth keeping.
        let recording = session.finish(at: .seconds(70))
        XCTAssertEqual(recording?.isComplete, false)
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
