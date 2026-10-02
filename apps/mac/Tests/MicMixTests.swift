import XCTest

/// a mic's channels down to the one `you` channel: only the channels that
/// carry the voice are averaged, so a quiet room on three inputs does not
/// divide the fourth by four.
final class MicMixTests: XCTestCase {
    private let voice: [Float] = (0..<512).map { sin(Float($0) * 0.05) * 0.3 }
    private let silence = [Float](repeating: 0, count: 512)

    /// an audio interface with four inputs and one mic plugged in.
    func testOneLiveChannelOfFourKeepsItsLevel() {
        XCTAssertEqual(MicMix.mono([silence, voice, silence, silence]), voice)
    }

    /// a stereo mic, one side a little further from the mouth: both carry
    /// the voice, so both are heard.
    func testChannelsWithinTwentyDecibelsOfTheLoudestAreAveraged() {
        let farther = voice.map { $0 * 0.5 }

        XCTAssertEqual(MicMix.mono([voice, farther]), voice.map { $0 * 0.75 })
    }

    /// a stereo mic on both sides of the same capsule.
    func testTwoEqualChannelsKeepTheirLevel() {
        XCTAssertEqual(MicMix.mono([voice, voice]), voice)
    }

    /// the other inputs on the interface hiss a little: more than 20 dB
    /// under the voice, they are left out rather than averaged in.
    func testAChannelMoreThanTwentyDecibelsDownIsLeftOut() {
        let hiss = voice.map { $0 * 0.05 }

        XCTAssertEqual(MicMix.mono([hiss, voice, hiss, hiss]), voice)
    }

    func testAllSilentStaysSilent() {
        XCTAssertEqual(MicMix.mono([silence, silence, silence, silence]), silence)
    }

    func testOneChannelIsUsedAsItIs() {
        XCTAssertEqual(MicMix.mono([voice]), voice)
    }

    // MARK: - which channels are the mic's

    /// the built-in mic's one channel, then the tap's two.
    func testTheMicsChannelsComeFirst() {
        XCTAssertEqual(MicMix.micChannels(said: 1, carried: 3), 1)
        XCTAssertEqual(MicMix.micChannels(said: 4, carried: 6), 4)
    }

    /// an aggregate the user made, inside ours: the HAL leaves its channels
    /// out, and the buffer is the tap's two alone. `you` gets none of them —
    /// read as the mic, the far side would be heard twice, once as you.
    func testABufferShortOfTheMicsChannelsGivesYouNoneOfTheTaps() {
        XCTAssertEqual(MicMix.micChannels(said: 1, carried: 2), 0)
        XCTAssertEqual(MicMix.micChannels(said: 4, carried: 4), 2)
    }
}
