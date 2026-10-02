import XCTest

final class CaptureInterruptionNoticeTests: XCTestCase {
    /// the take is kept and pasted; the pill after the paste says why it
    /// ended without you, in the cap's voice.
    func testAMicChangeSaysWhatItPasted() {
        XCTAssertEqual(
            CaptureInterruptionNotice.message(for: .deviceChanged),
            "the mic changed — pasted what i had."
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
