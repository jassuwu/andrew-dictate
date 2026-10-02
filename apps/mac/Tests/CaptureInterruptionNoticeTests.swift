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

    /// sleep and the lock keep the take too, on the clipboard: the pill
    /// waits for you to come back and says where the words went, in the
    /// other copies' voice.
    func testSleepAndTheLockSayWhereTheWordsWent() {
        XCTAssertEqual(
            CaptureInterruptionNotice.message(for: .systemPaused),
            "copied — what you said before the lock · ⌘V to paste"
        )
    }
}
