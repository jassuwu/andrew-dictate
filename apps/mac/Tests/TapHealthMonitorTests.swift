import XCTest

final class TapHealthMonitorTests: XCTestCase {
    private func monitor() -> TapHealthMonitor {
        TapHealthMonitor(
            probeTimeout: .milliseconds(500),
            silenceTimeout: .seconds(8),
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

    func testSamplesUnderTheFloorCountAsSilence() {
        var monitor = monitor()
        monitor.observe(rms: 0.0005, elapsed: .milliseconds(600))

        XCTAssertEqual(monitor.verdict, .neverHeardTheProbeTone)
    }

    // MARK: - died mid-session

    /// 002 §6: "always occurs after extended uptime — first few minutes are
    /// consistently clean". Having heard audio once is what separates this
    /// from a denied grant, and the two need different responses.
    func testGoingSilentAfterCapturingIsADeadTapNotADeniedOne() {
        var monitor = monitor()
        monitor.observe(rms: 0.4, elapsed: .milliseconds(120))
        monitor.observe(rms: 0, elapsed: .seconds(5))
        XCTAssertEqual(monitor.verdict, .capturing)

        monitor.observe(rms: 0, elapsed: .seconds(9))
        XCTAssertEqual(monitor.verdict, .wentSilent)
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
        monitor.observe(rms: 0, elapsed: .seconds(40))
        XCTAssertEqual(monitor.verdict, .wentSilent)

        monitor.observe(rms: 0.5, elapsed: .seconds(41))
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

    // MARK: - what the app does about it

    func testOnlyTheTwoFailuresAskForAction() {
        XCTAssertNil(TapHealthMonitor.Verdict.waitingForProbeTone.response)
        XCTAssertNil(TapHealthMonitor.Verdict.capturing.response)
        XCTAssertEqual(
            TapHealthMonitor.Verdict.neverHeardTheProbeTone.response,
            .tellTheUser
        )
        XCTAssertEqual(
            TapHealthMonitor.Verdict.wentSilent.response,
            .rebuildTheTap
        )
    }
}
