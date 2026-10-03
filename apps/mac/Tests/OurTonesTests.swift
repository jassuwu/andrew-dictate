import AVFoundation
import XCTest

/// How long the app's own tones last in the far side, held to the sound
/// file the start sound is played from.
final class OurTonesTests: XCTestCase {
    /// Silenced for less than it lasts, the end of the start sound would
    /// reach the transcriber as somebody speaking; for a lot longer, the
    /// words of someone already talking would not.
    func testTheStartSoundLastsAsLongAsItsFileAndNoLonger() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/Sounds/dictation-start.wav")
        let file = try AVAudioFile(forReading: url)
        let length = Duration.seconds(Double(file.length) / file.fileFormat.sampleRate)

        XCTAssertGreaterThanOrEqual(OurTones.startSound, length)
        XCTAssertLessThan(OurTones.startSound - length, .milliseconds(5))
    }
}
