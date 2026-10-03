import XCTest

final class TapHealthMonitorTests: XCTestCase {
    private func monitor() -> TapHealthMonitor {
        TapHealthMonitor(
            probeTimeout: .milliseconds(500),
            silenceTimeout: .seconds(8),
            quietProbeWindow: .seconds(2),
            silenceFloor: 0.001
        )
    }

    func testStartsWaitingForTheProbeTone() {
        XCTAssertEqual(monitor().verdict, .waitingForProbeTone)
    }

    func testHearingTheProbeToneMeansThePermissionIsReal() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))

        XCTAssertEqual(monitor.verdict, .capturing)
    }

    /// The whole point of playing a known sound: silence here is not "nobody
    /// spoke", it is "we made a noise and the tap did not hear it".
    func testSilenceThroughTheProbeWindowIsProofRatherThanAmbiguity() {
        var monitor = monitor()
        monitor.observe(rms: 0, elapsed: .milliseconds(300))
        XCTAssertEqual(monitor.verdict, .waitingForProbeTone)

        monitor.observe(rms: 0, elapsed: .milliseconds(501))
        XCTAssertEqual(monitor.verdict, .neverHeardTheProbeTone)
    }

    /// The start sound could not be played, so the tap had nothing to hear:
    /// the probe window passing in silence is not a verdict, and from then
    /// on the tap is treated like one that worked — asked again, quietly,
    /// if the far side stays silent while something plays.
    func testAProbeToneThatCouldNotPlayIsNotNeverHearingIt() {
        var monitor = monitor()
        monitor.probeToneCouldNotPlay(at: .zero)

        monitor.observe(rms: 0, elapsed: .seconds(2), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing)
        monitor.observe(rms: 0, elapsed: .milliseconds(8_100), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)
    }

    func testSamplesUnderTheFloorCountAsSilence() {
        var monitor = monitor()
        monitor.observe(rms: 0.0005, elapsed: .milliseconds(600))

        XCTAssertEqual(monitor.verdict, .neverHeardTheProbeTone)
    }

    // MARK: - died mid-session

    /// 002 §6: "always occurs after extended uptime — first few minutes are
    /// consistently clean". Having heard audio once is what separates this
    /// from a denied grant, and the two need different responses: a tap
    /// that worked and then missed our own quiet tone is a dead one.
    func testMissingTheQuietProbeAfterCapturingIsADeadTapNotADeniedOne() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(9), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)

        monitor.askedWithTheQuietProbe(at: .seconds(9))
        XCTAssertEqual(monitor.verdict, .waitingForQuietProbe)
        monitor.observe(rms: 0, elapsed: .seconds(11), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .waitingForQuietProbe, "the window is not over")

        monitor.observe(rms: 0, elapsed: .milliseconds(11_100), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .missedTheQuietProbe)
        XCTAssertEqual(monitor.verdict.response, .rebuildTheTap)
    }

    /// Heard, the tap is fine and nothing happens — and the silence is
    /// timed again from the tone, so the next question waits a full timeout.
    func testAQuietProbeTheTapHearsClearsItAndTheClockStartsOver() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(9), anythingIsPlaying: true)
        monitor.askedWithTheQuietProbe(at: .seconds(9))

        monitor.observe(rms: 0.007, elapsed: .milliseconds(9_400), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing)

        monitor.observe(rms: 0, elapsed: .milliseconds(17_400), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing, "eight seconds since the tone, not more")
        monitor.observe(rms: 0, elapsed: .milliseconds(17_500), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)
    }

    /// A tone that could not be played at all — no output device, a player
    /// that would not start — asked the tap nothing. It is neither cleared
    /// nor accused, and the silence is timed afresh from there, so the
    /// question comes round again a full timeout later.
    func testAQuietProbeThatCouldNotPlayIsNoEvidence() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(9), anythingIsPlaying: true)
        monitor.askedWithTheQuietProbe(at: .seconds(9))

        monitor.quietProbeCouldNotPlay(at: .seconds(9))
        monitor.observe(rms: 0, elapsed: .seconds(12), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing, "never played, so never missed")

        monitor.observe(rms: 0, elapsed: .seconds(17), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing)
        monitor.observe(rms: 0, elapsed: .milliseconds(17_100), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)
    }

    /// Asked once, it is not asked again while it waits for the answer.
    func testAQuestionIsAskedOnceAndStandsUntilAnswered() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(9), anythingIsPlaying: true)
        monitor.observe(rms: 0, elapsed: .seconds(10), anythingIsPlaying: false)

        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)
    }

    /// People stop talking. A pause is not a dead tap, which is why the
    /// silence timeout is seconds rather than buffers.
    func testAPauseShorterThanTheTimeoutIsNotAFailure() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(7))

        XCTAssertEqual(monitor.verdict, .capturing)
    }

    func testTheSilenceTimerRestartsEveryTimeAudioReturns() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(7))
        monitor.observe(rms: 0.3, elapsed: .seconds(8))
        monitor.observe(rms: 0, elapsed: .seconds(15))

        XCTAssertEqual(monitor.verdict, .capturing)
    }

    /// The report observed "sporadic recovery". A verdict that could not
    /// climb back would leave the app claiming a failure that had stopped.
    func testADeadTapThatRecoversIsCapturingAgain() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(40), anythingIsPlaying: true)
        monitor.askedWithTheQuietProbe(at: .seconds(40))
        monitor.observe(rms: 0, elapsed: .seconds(43), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .missedTheQuietProbe)

        monitor.observe(rms: 0.5, elapsed: .seconds(44))
        XCTAssertEqual(monitor.verdict, .capturing)
    }

    /// A missed tone means the probe window was too short, not that the
    /// permission is missing. Evidence of real audio outranks the guess.
    func testLateAudioOverturnsANeverHeardVerdict() {
        var monitor = monitor()
        monitor.observe(rms: 0, elapsed: .milliseconds(600))
        XCTAssertEqual(monitor.verdict, .neverHeardTheProbeTone)

        monitor.observe(rms: 0.5, elapsed: .seconds(2))
        XCTAssertEqual(monitor.verdict, .capturing)
    }

    // MARK: - quiet rooms

    /// Two minutes of nothing while the mac plays nothing is a quiet room,
    /// not a dead tap: the recording carries on, no gap is recorded, and no
    /// start sound goes off in the middle of a call.
    func testAMacThatIsPlayingNothingIsNeverCalledADeadTap() {
        var monitor = monitor()
        monitor.observe(rms: 0.5, elapsed: .seconds(1))

        monitor.observe(rms: 0, elapsed: .seconds(200), anythingIsPlaying: false)

        XCTAssertEqual(monitor.verdict, .capturing)
    }

    /// The other direction is not proof: a room of muted participants still
    /// satisfies `isRunningOutput` (002 §6), and so does you presenting to
    /// them. Silence past the timeout while the mac says it is playing is a
    /// question to put to the tap, not an answer.
    func testSilenceWhileSomethingPlaysIsAQuestionNotAVerdict() {
        var monitor = monitor()
        monitor.observe(rms: 0.5, elapsed: .seconds(1))

        monitor.observe(rms: 0, elapsed: .seconds(5), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .capturing)

        monitor.observe(rms: 0, elapsed: .seconds(10), anythingIsPlaying: true)
        XCTAssertEqual(monitor.verdict, .silentWhileSomethingPlays)
        XCTAssertEqual(monitor.verdict.response, .askWithTheQuietProbe)
    }

    /// A question the HAL would not answer is not a yes. Silence from a mac
    /// that may be playing nothing is no more a dead tap than silence from
    /// one that says so.
    func testAnUnanswerableQuestionAccusesNothing() {
        var monitor = monitor()
        monitor.observe(rms: 0.5, elapsed: .seconds(1))

        monitor.observe(rms: 0, elapsed: .seconds(200), anythingIsPlaying: nil)

        XCTAssertEqual(monitor.verdict, .capturing)
    }

    // MARK: - what the app does about it

    /// The two failures ask for action, and so does the one question;
    /// waiting for an answer asks for nothing.
    func testOnlyTheTwoFailuresAndTheQuestionAskForAction() {
        XCTAssertNil(TapHealthMonitor.Verdict.waitingForProbeTone.response)
        XCTAssertNil(TapHealthMonitor.Verdict.capturing.response)
        XCTAssertNil(TapHealthMonitor.Verdict.waitingForQuietProbe.response)
        XCTAssertEqual(
            TapHealthMonitor.Verdict.neverHeardTheProbeTone.response,
            .tellTheUser
        )
        XCTAssertEqual(
            TapHealthMonitor.Verdict.silentWhileSomethingPlays.response,
            .askWithTheQuietProbe
        )
        XCTAssertEqual(
            TapHealthMonitor.Verdict.missedTheQuietProbe.response,
            .rebuildTheTap
        )
    }
}
