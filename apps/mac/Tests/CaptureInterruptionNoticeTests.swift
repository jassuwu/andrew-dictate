import XCTest

final class CaptureInterruptionNoticeTests: XCTestCase {
    func testALostMicrophoneSaysSo() {
        XCTAssertEqual(
            CaptureInterruptionNotice.message(for: .deviceChanged),
            "the microphone changed — say that again"
        )
    }

    /// sleeping and locking were always silent, and stay that way: nobody is
    /// looking at the screen to read the pill.
    func testSleepAndLockStaySilent() {
        XCTAssertNil(
            CaptureInterruptionNotice.message(for: .systemPaused)
        )
    }
}
