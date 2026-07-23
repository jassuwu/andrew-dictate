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
                delivery: .milliseconds(300),
                keyUpToCompletion: .milliseconds(503),
                total: .milliseconds(1_515)
            )
        )
    }
}
