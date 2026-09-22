import XCTest

final class OnboardingModelCaptionTests: XCTestCase {
    /// The line that used to be shown to everybody. It is only true for the
    /// user who never saw the bar move.
    func testACacheHitSaysNothingWasDownloaded() {
        XCTAssertEqual(
            OnboardingState.modelReadyCaption(wasOnDisk: true),
            "already on this mac. nothing to download."
        )
    }

    /// Telling someone who just watched ~460 mb arrive that nothing was
    /// downloaded is the first caption they can check, and it was wrong.
    func testARealDownloadSaysSo() {
        XCTAssertEqual(
            OnboardingState.modelReadyCaption(wasOnDisk: false),
            "downloaded. it stays on this mac."
        )
    }
}
