import XCTest

final class HUDFeedbackGateTests: XCTestCase {
    func testAFreshMessageFlashesWhenTheScreenIsFree() {
        XCTAssertEqual(
            HUDFeedbackGate.decide(
                isOnboardingPresented: false,
                heldFor: nil
            ),
            .flashNow
        )
    }

    /// the setup window force-dismisses the panel, so a timed pill would be
    /// spent behind it and lost for good.
    func testTheSetupWindowHoldsTheMessageInstead() {
        XCTAssertEqual(
            HUDFeedbackGate.decide(
                isOnboardingPresented: true,
                heldFor: nil
            ),
            .hold
        )
        XCTAssertEqual(
            HUDFeedbackGate.decide(
                isOnboardingPresented: true,
                heldFor: 2
            ),
            .hold
        )
    }

    func testClosingSetupFlushesWhatWasHeld() {
        for heldFor in [0, 1.2, HUDFeedbackGate.holdLimit] {
            XCTAssertEqual(
                HUDFeedbackGate.decide(
                    isOnboardingPresented: false,
                    heldFor: heldFor
                ),
                .flashNow
            )
        }
    }

    /// "heard nothing" arriving after a minute in setup is a non-sequitur,
    /// not a kindness.
    func testAStaleMessageIsDroppedRatherThanArrivingLate() {
        XCTAssertEqual(
            HUDFeedbackGate.decide(
                isOnboardingPresented: false,
                heldFor: HUDFeedbackGate.holdLimit + 0.1
            ),
            .drop
        )
    }
}
