import AVFoundation
import XCTest

/// the audio thread's answer to "was any of it sound": real buffers, the
/// shape the tap and the sink hand over. a dead device's exact zeros are
/// not sound; the faintest hiss is.
final class AudioSoundFlagTests: XCTestCase {
    func testExactZerosAreNotSound() throws {
        let flag = AudioSoundFlag()
        flag.listen(judgingSamples: true)

        flag.hear(try buffer(Array(repeating: 0, count: 480)).audioBufferList)

        XCTAssertFalse(flag.hasHeardSound)
    }

    func testTheFaintestHissIsSound() throws {
        let flag = AudioSoundFlag()
        flag.listen(judgingSamples: true)
        var samples = [Float](repeating: 0, count: 480)
        samples[479] = -0.000_01

        flag.hear(try buffer(samples).audioBufferList)

        XCTAssertTrue(flag.hasHeardSound)
    }

    /// once heard, an utterance stays heard; the next one starts over.
    func testEachUtteranceStartsOver() throws {
        let flag = AudioSoundFlag()
        flag.listen(judgingSamples: true)
        flag.hear(try buffer([0.2, 0, 0]).audioBufferList)
        flag.hear(try buffer([0, 0, 0]).audioBufferList)
        XCTAssertTrue(flag.hasHeardSound)

        flag.stopListening()
        XCTAssertFalse(flag.hasHeardSound)
        flag.listen(judgingSamples: true)
        XCTAssertFalse(flag.hasHeardSound)
    }

    /// between utterances the audio thread looks at nothing.
    func testNothingIsHeardWhileNotListening() throws {
        let flag = AudioSoundFlag()

        flag.hear(try buffer([0.5, 0.5]).audioBufferList)

        XCTAssertFalse(flag.hasHeardSound)
    }

    /// samples it can't read as floats are taken on trust.
    func testSamplesItCannotJudgeCountAsSound() {
        let flag = AudioSoundFlag()

        flag.listen(judgingSamples: false)

        XCTAssertTrue(flag.hasHeardSound)
    }

    private func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData![0][index] = sample
        }
        return buffer
    }
}
