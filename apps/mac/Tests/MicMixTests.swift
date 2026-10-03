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

    // MARK: - a buffer unlike the first

    /// a buffer like its rig's first is read as the first was.
    func testABufferLikeTheFirstIsReadAsItWas() {
        XCTAssertEqual(MicMix.micChannels(said: 1, first: 3, carried: 3), 1)
        XCTAssertEqual(MicMix.micChannels(said: 4, first: 6, carried: 6), 4)
        XCTAssertEqual(MicMix.micChannels(said: 1, first: 1, carried: 1, tap: 0), 1)
    }

    /// the airpods died, and the rig they were in calls back with the tap's
    /// two channels alone: still the far side, and `you` is silence — not
    /// a buffer dropped whole, with the far side in it.
    func testABufferWithTheTapsChannelsAloneIsTheFarSideWithASilentYou() {
        XCTAssertEqual(MicMix.micChannels(said: 1, first: 3, carried: 2), 0)
        XCTAssertEqual(MicMix.micChannels(said: 4, first: 6, carried: 2), 0)
    }

    /// any other change — a mic with a channel more, or one fewer — leaves
    /// which channel is whose a guess, and the buffer is not read. the mic
    /// alone has no tap to keep.
    func testAnyOtherChangeIsNotRead() {
        XCTAssertNil(MicMix.micChannels(said: 1, first: 3, carried: 4))
        XCTAssertNil(MicMix.micChannels(said: 2, first: 4, carried: 3))
        XCTAssertNil(MicMix.micChannels(said: 2, first: 2, carried: 1, tap: 0))
    }

    /// a rig with the mic alone, while the tap cannot be rebuilt, has no
    /// tap channels after the mic's: every channel it carries is `you`,
    /// and none of it is ever read as the far side.
    func testWithNoTapEveryChannelIsTheMics() {
        XCTAssertEqual(MicMix.micChannels(said: 1, carried: 1, tap: 0), 1)
        XCTAssertEqual(MicMix.micChannels(said: 4, carried: 4, tap: 0), 4)
        XCTAssertEqual(MicMix.micChannels(said: 4, carried: 2, tap: 0), 2)
    }
}
