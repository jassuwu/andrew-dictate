import XCTest

/// a slow model is given longer, so it is not restarted for being slow.
final class TranscriptionPaceTests: XCTestCase {
    private let tenSeconds = 160_000
    private let aMinute = 960_000

    func testParakeetKeepsTheDeadlineItAlwaysHad() {
        XCTAssertEqual(TranscriptionDeadline.forSamples(tenSeconds, pace: SpeechModel.parakeetV2.dictationPace), .seconds(4))
        XCTAssertEqual(TranscriptionDeadline.forSamples(aMinute, pace: SpeechModel.parakeetV3.dictationPace), .seconds(15))
    }

    func testWhisperLargeGetsTheTakesOwnLength() {
        let pace = SpeechModel.whisperLargeV3.dictationPace

        XCTAssertEqual(TranscriptionDeadline.forSamples(tenSeconds, pace: pace), .seconds(20))
        XCTAssertEqual(TranscriptionDeadline.forSamples(aMinute, pace: pace), .seconds(60))
    }
}
