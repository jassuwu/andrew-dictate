import XCTest

final class OnboardingStateTests: XCTestCase {
    func testSingleConsentIsTheOnlySetupStartSignal() {
        var state = OnboardingState()
        var setupStartCount = 0

        XCTAssertFalse(state.consented)
        XCTAssertFalse(state.autoFinishArmed)
        XCTAssertEqual(setupStartCount, 0)

        if state.consentToSetup() {
            setupStartCount += 1
        }
        if state.consentToSetup() {
            setupStartCount += 1
        }

        XCTAssertTrue(state.consented)
        XCTAssertEqual(setupStartCount, 1)
        XCTAssertEqual(state.accessibilityStatus, .actionRequired)
    }

    func testAutoFinishArmsOnlyWhenAllThreeRowsAreReady() {
        for microphoneReady in [false, true] {
            for accessibilityReady in [false, true] {
                for modelReady in [false, true] {
                    var state = OnboardingState()
                    _ = state.consentToSetup()
                    state.updateMicrophoneStatus(
                        microphoneReady ? .ready : .pending
                    )
                    state.updateAccessibility(
                        granted: accessibilityReady
                    )
                    state.updateModelStatus(
                        modelReady ? .ready : .pending
                    )

                    let allReady =
                        microphoneReady
                            && accessibilityReady
                            && modelReady
                    XCTAssertEqual(state.autoFinishArmed, allReady)
                    XCTAssertEqual(
                        state.finishAutomatically(),
                        allReady
                    )
                    XCTAssertEqual(
                        state.completion,
                        allReady ? .finished : .pending
                    )
                }
            }
        }
    }

    func testDeniedMicrophoneKeepsCardOpenWithSettingsStatus() {
        var state = OnboardingState()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.actionRequired)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)

        XCTAssertEqual(state.microphoneStatus, .actionRequired)
        XCTAssertFalse(state.autoFinishArmed)
        XCTAssertFalse(state.finishAutomatically())
        XCTAssertEqual(state.completion, .pending)
    }

    func testSkipCompletesWithoutConsentOrStartingSetup() {
        var state = OnboardingState()

        XCTAssertTrue(state.skipForNow())
        XCTAssertEqual(state.completion, .skipped)
        XCTAssertFalse(state.consented)
        XCTAssertFalse(state.consentToSetup())
        XCTAssertFalse(state.finishAutomatically())
    }

    func testAllGreenRelaunchAutoFinishesWithoutSetupRetrigger() {
        var state = OnboardingState()
        var setupStartCount = 0
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)

        XCTAssertFalse(state.consented)
        XCTAssertEqual(setupStartCount, 0)
        XCTAssertTrue(state.autoFinishArmed)
        XCTAssertTrue(state.finishAutomatically())
        XCTAssertEqual(state.completion, .finished)

        if state.consentToSetup() {
            setupStartCount += 1
        }
        XCTAssertEqual(setupStartCount, 0)
    }

    func testLosingReadinessDisarmsAutoFinish() {
        var state = OnboardingState()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)
        XCTAssertTrue(state.autoFinishArmed)

        state.updateModelStatus(.actionRequired)

        XCTAssertFalse(state.autoFinishArmed)
        XCTAssertEqual(state.modelStatus, .actionRequired)
        XCTAssertEqual(state.completion, .pending)
    }
}
