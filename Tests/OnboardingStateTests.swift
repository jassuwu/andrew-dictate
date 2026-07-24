import XCTest

final class OnboardingStateTests: XCTestCase {
    func testPermissionsRequireBothGrants() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .permissions)

        state.updatePermissions(
            microphoneGranted: true,
            accessibilityGranted: false
        )
        XCTAssertFalse(state.canContinue)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .permissions)

        state.updatePermissions(
            microphoneGranted: true,
            accessibilityGranted: true
        )
        XCTAssertTrue(state.canContinue)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .keysAndAgent)
    }

    func testPermissionSkipAllowsSetupStep() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())

        state.skipPermissions()

        XCTAssertTrue(state.canContinue)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .keysAndAgent)
    }

    func testSetupNeverWaitsForModelAndFinalRequiresReadyState() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())
        state.skipPermissions()
        XCTAssertTrue(state.advance())

        XCTAssertEqual(state.step, .keysAndAgent)
        XCTAssertTrue(state.canContinue)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .model)

        XCTAssertFalse(state.canContinue)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .model)

        state.updateEngineReady(true)

        XCTAssertTrue(state.canContinue)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .model)
    }

    func testBackNavigationPreservesSatisfiedGates() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())
        state.skipPermissions()
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.advance())
        state.updateEngineReady(true)

        state.goBack()
        XCTAssertEqual(state.step, .keysAndAgent)
        XCTAssertTrue(state.canContinue)

        state.goBack()
        XCTAssertEqual(state.step, .permissions)
        XCTAssertTrue(state.canContinue)
    }
}
