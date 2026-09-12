import XCTest

final class EnginePrewarmGateTests: XCTestCase {
    func testNothingDownloadsBeforeSetupHasBeenThrough() {
        XCTAssertFalse(
            EnginePrewarmGate.shouldPrewarmAtLaunch(
                onboardingDismissed: false,
                dictationWanted: true
            )
        )
    }

    func testADictationMacPrewarmsAtEveryLaunch() {
        XCTAssertTrue(
            EnginePrewarmGate.shouldPrewarmAtLaunch(
                onboardingDismissed: true,
                dictationWanted: true
            )
        )
    }

    /// The bug this gate exists for: a meetings-only setup watching ~460 mb
    /// arrive on the next launch for a job it unticked.
    func testAJobYouUntickedNeverDownloadsLater() {
        XCTAssertFalse(
            EnginePrewarmGate.shouldPrewarmAtLaunch(
                onboardingDismissed: true,
                dictationWanted: false
            )
        )
    }
}
