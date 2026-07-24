import XCTest

final class UtteranceTimelineTests: XCTestCase {
    func testDerivedDurationsUseTheExpectedStageBoundaries() {
        let keyDown = ContinuousClock.now
        let timeline = UtteranceTimeline(
            mode: .dictation,
            keyDown: keyDown,
            micFirstBuffer: keyDown.advanced(by: .milliseconds(12)),
            keyUp: keyDown.advanced(by: .milliseconds(1_012)),
            transcriptReady: keyDown.advanced(by: .milliseconds(1_212)),
            cleaned: keyDown.advanced(by: .milliseconds(1_215)),
            polished: keyDown.advanced(by: .milliseconds(1_495)),
            completionStage: .pasteVerified,
            completed: keyDown.advanced(by: .milliseconds(1_515))
        )

        XCTAssertEqual(
            timeline.durations,
            UtteranceTimeline.Durations(
                microphoneStartup: .milliseconds(12),
                held: .milliseconds(1_012),
                capturedAudio: .milliseconds(1_000),
                transcription: .milliseconds(200),
                cleanup: .milliseconds(3),
                polish: .milliseconds(280),
                delivery: .milliseconds(20),
                keyUpToCompletion: .milliseconds(503),
                total: .milliseconds(1_515)
            )
        )
    }

    func testCancellationStagesMeasureCancelRequestedToIdle() {
        let keyDown = ContinuousClock.now
        var builder = UtteranceTimelineBuilder(
            id: 1,
            mode: .command,
            keyDown: keyDown
        )
        builder.micFirstBuffer = keyDown.advanced(
            by: .milliseconds(10)
        )
        builder.keyUp = keyDown.advanced(by: .milliseconds(500))
        builder.transcriptReady = keyDown.advanced(
            by: .milliseconds(700)
        )
        builder.cleaned = keyDown.advanced(by: .milliseconds(702))

        let timeline = builder.cancelled(
            requestedAt: keyDown.advanced(by: .milliseconds(900)),
            idleAt: keyDown.advanced(by: .milliseconds(940))
        )

        XCTAssertEqual(timeline.completionStage, .cancelled)
        XCTAssertEqual(
            timeline.durations.cancelToIdle,
            .milliseconds(40)
        )
    }

    func testPolishGateDecisionIsRetainedByBuilder() {
        let keyDown = ContinuousClock.now
        var builder = UtteranceTimelineBuilder(
            id: 1,
            mode: .dictation,
            keyDown: keyDown
        )
        builder.micFirstBuffer = keyDown
        builder.keyUp = keyDown
        builder.transcriptReady = keyDown
        builder.cleaned = keyDown
        builder.polished = keyDown
        builder.polishGateDecision = false

        let timeline = builder.complete(
            .pasteVerified,
            at: keyDown
        )

        XCTAssertEqual(timeline?.polishGateDecision, false)
    }
}
