import XCTest

final class TranscribingRepressTests: XCTestCase {
    /// the common case: you talk in bursts and press again ~200 ms after
    /// letting go. the sentence in flight is worth more than the new one.
    func testAPressRightAfterLettingGoKeepsTheLastSentence() {
        XCTAssertEqual(
            TranscribingRepress.response(transcribingFor: 0.2),
            .refuseAndSayWhy
        )
    }

    /// there is no transcription timeout anywhere, so a hung pipeline must
    /// never be able to wedge the dictation key.
    func testAHungPipelineNeverWedgesTheKey() {
        XCTAssertEqual(
            TranscribingRepress.response(transcribingFor: 5),
            .dropAndRestart
        )
    }

    func testThePatienceBoundaryIsTheSwitch() {
        XCTAssertEqual(
            TranscribingRepress.response(
                transcribingFor: TranscribingRepress.patience - 0.01
            ),
            .refuseAndSayWhy
        )
        XCTAssertEqual(
            TranscribingRepress.response(
                transcribingFor: TranscribingRepress.patience
            ),
            .dropAndRestart
        )
    }
}
