import XCTest

final class HUDPresentationTests: XCTestCase {
    private func shouldPresent(
        _ state: HUDLampState,
        hasFeedback: Bool = false,
        isOnboarding: Bool = false,
        prewarmPresentsHUD: Bool = true
    ) -> Bool {
        HUDPresentation.shouldPresent(
            state: state,
            hasFeedback: hasFeedback,
            isOnboarding: isOnboarding,
            prewarmPresentsHUD: prewarmPresentsHUD
        )
    }

    /// launch-at-login warms the model up without being asked, and the
    /// bottom of the screen stays empty.
    func testAWarmUpNobodyAskedForShowsNothing() {
        XCTAssertFalse(
            shouldPresent(.prewarming, prewarmPresentsHUD: false)
        )
    }

    func testAWarmUpUnderAPressedKeyShowsTheEmber() {
        XCTAssertTrue(
            shouldPresent(.prewarming, prewarmPresentsHUD: true)
        )
    }

    /// the suppression is about an unprompted glow, not about silence:
    /// anything exceptional still gets said.
    func testAMessageSpeaksEvenDuringAnUnaskedWarmUp() {
        XCTAssertTrue(
            shouldPresent(
                .prewarming,
                hasFeedback: true,
                prewarmPresentsHUD: false
            )
        )
    }

    func testTheLampShowsWhileListeningAndWriting() {
        for state in [HUDLampState.recording, .transcribing] {
            XCTAssertTrue(shouldPresent(state))
            XCTAssertTrue(
                shouldPresent(state, prewarmPresentsHUD: false)
            )
        }
    }

    func testIdleShowsNothingUnlessThereIsSomethingToSay() {
        XCTAssertFalse(shouldPresent(.idle))
        XCTAssertTrue(shouldPresent(.idle, hasFeedback: true))
    }

    /// a question (a pill with a button) asks only when nothing else is on
    /// the screen: not over a take, not over a sentence, not over setup.
    func testAQuestionAsksOnlyWhenTheLampIsIdleAndNothingIsSaid() {
        func free(
            _ state: HUDLampState,
            hasFeedback: Bool = false,
            isOnboarding: Bool = false
        ) -> Bool {
            HUDPresentation.pillIsFreeForAQuestion(
                state: state,
                hasFeedback: hasFeedback,
                isOnboarding: isOnboarding
            )
        }

        XCTAssertTrue(free(.idle))
        XCTAssertFalse(free(.idle, hasFeedback: true))
        XCTAssertFalse(free(.idle, isOnboarding: true))
        // the lamp coming back to idle wipes the pill, so a question asked
        // under an ember, even one nobody sees, would be wiped with it.
        for state in [HUDLampState.prewarming, .recording, .transcribing] {
            XCTAssertFalse(free(state), "\(state)")
        }
    }

    /// the setup window takes the screen, and the panel steps aside — as
    /// it does today, for every state and every message.
    func testSetupTakesTheScreenFromEveryState() {
        for state in [
            HUDLampState.idle,
            .prewarming,
            .recording,
            .transcribing
        ] {
            XCTAssertFalse(
                shouldPresent(state, isOnboarding: true)
            )
            XCTAssertFalse(
                shouldPresent(
                    state,
                    hasFeedback: true,
                    isOnboarding: true
                )
            )
        }
    }
}
