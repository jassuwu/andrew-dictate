import XCTest

/// whether the meeting's mic is muted on the mac, read from its own
/// controls every few seconds, and told when that changes.
final class MicMuteTests: XCTestCase {
    /// the mute switch, told once however many reads find it on.
    func testAMuteSwitchOnIsMutedAndToldOnce() {
        var mute = MicMute()
        XCTAssertEqual(mute.read(mute: true, volume: 0.5), .micMuted)
        XCTAssertNil(mute.read(mute: true, volume: 0.5))
        XCTAssertTrue(mute.muted)
    }

    /// the input slider dragged all the way down is a mute by another name.
    func testAnInputVolumeAtNothingIsMuted() {
        var mute = MicMute()
        XCTAssertEqual(mute.read(mute: false, volume: 0), .micMuted)
    }

    /// turned down is not turned off: a quiet mic is still a mic.
    func testAnInputVolumeTurnedDownButNotOffIsNotMuted() {
        var mute = MicMute()
        XCTAssertNil(mute.read(mute: false, volume: 0.05))
        XCTAssertFalse(mute.muted)
    }

    /// back up, or the switch off, and it is told once.
    func testUnmutingIsToldOnce() {
        var mute = MicMute()
        _ = mute.read(mute: false, volume: 0)
        XCTAssertEqual(mute.read(mute: false, volume: 0.27), .micUnmuted)
        XCTAssertNil(mute.read(mute: false, volume: 0.27))
    }

    /// a mic with neither control — many usb mics, an aggregate input —
    /// cannot be muted on the mac, and is never taken for muted.
    func testAMicWithNoControlsIsNeverMuted() {
        var mute = MicMute()
        XCTAssertNil(mute.read(mute: nil, volume: nil))
        XCTAssertFalse(mute.muted)
    }
}
