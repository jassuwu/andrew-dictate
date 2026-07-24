import XCTest

final class OnboardingStateTests: XCTestCase {
    func testConsentEnablesSectionsAndGatesSkip() {
        var state = OnboardingState()

        XCTAssertFalse(state.sectionsEnabled)
        XCTAssertFalse(state.skipForNow())
        XCTAssertEqual(state.completion, .pending)

        state.consentToSetup()

        XCTAssertTrue(state.sectionsEnabled)
    }

    func testFinishGatingForEveryReadinessCombination() {
        for microphoneGranted in [false, true] {
            for accessibilityGranted in [false, true] {
                for engineReady in [false, true] {
                    var state = OnboardingState()
                    state.consentToSetup()
                    state.updatePermissions(
                        microphoneGranted: microphoneGranted,
                        accessibilityGranted: accessibilityGranted
                    )
                    state.updateEngine(
                        preparationStarted: true,
                        ready: engineReady
                    )

                    var expectedMissingItems:
                        [OnboardingMissingItem] = []
                    if !microphoneGranted {
                        expectedMissingItems.append(.microphone)
                    }
                    if !accessibilityGranted {
                        expectedMissingItems.append(.accessibility)
                    }
                    if !engineReady {
                        expectedMissingItems.append(.model)
                    }
                    let shouldFinish =
                        microphoneGranted
                            && accessibilityGranted
                            && engineReady

                    XCTAssertEqual(
                        state.missingItems,
                        expectedMissingItems
                    )
                    XCTAssertEqual(state.finishEnabled, shouldFinish)
                    XCTAssertEqual(state.finish(), shouldFinish)
                    XCTAssertEqual(
                        state.completion,
                        shouldFinish ? .finished : .pending
                    )
                }
            }
        }
    }

    func testSkipCompletesWithoutPermissionsOrReadyModel() {
        var state = OnboardingState()
        state.consentToSetup()
        state.updateEngine(
            preparationStarted: true,
            ready: false
        )

        XCTAssertFalse(state.finishEnabled)
        XCTAssertTrue(state.skipForNow())
        XCTAssertEqual(state.completion, .skipped)
    }

    func testReadyModelRelaunchEnablesSectionsWithoutNewConsent() {
        var state = OnboardingState()
        state.updateEngine(
            preparationStarted: true,
            ready: true
        )

        XCTAssertFalse(state.setupConsented)
        XCTAssertTrue(state.sectionsEnabled)
        XCTAssertEqual(
            state.missingItems,
            [.microphone, .accessibility]
        )

        state.updatePermissions(
            microphoneGranted: true,
            accessibilityGranted: true
        )

        XCTAssertTrue(state.finishEnabled)
        XCTAssertTrue(state.finish())
        XCTAssertEqual(state.completion, .finished)
    }
}
