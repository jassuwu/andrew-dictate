import XCTest

/// which part of a rig would not come up, read from how far its build got:
/// the mic's once the mic is being started, the tap's before that, and a
/// mic that was not there at all the mic's wherever it was missed.
final class CaptureFaultTests: XCTestCase {
    private typealias Failure = CoreAudioMeetingSource.Failure

    func testAMicThatIsNotThereIsTheMics() {
        XCTAssertEqual(Failure.noMicrophone.fault, .mic(nil))
        XCTAssertEqual(Failure.micGone("AirPods Pro").fault, .mic("AirPods Pro"))
    }

    func testACallThatFailsOrHangsWhileTheMicStartsIsTheMics() {
        XCTAssertEqual(
            Failure.coreAudio("AudioDeviceStart", -50, .startingTheMic("Yeti")).fault, .mic("Yeti"))
        XCTAssertEqual(Failure.noAnswer(.startingTheMic("Yeti")).fault, .mic("Yeti"))
    }

    func testACallThatFailsOrHangsBeforeTheMicIsTheTaps() {
        XCTAssertEqual(
            Failure.coreAudio("AudioHardwareCreateProcessTap", -50, .openingTheTap).fault, .tap)
        XCTAssertEqual(Failure.noAnswer(.openingTheTap).fault, .tap)
        XCTAssertEqual(Failure.noAnswer(.waiting).fault, .tap)
    }
}
