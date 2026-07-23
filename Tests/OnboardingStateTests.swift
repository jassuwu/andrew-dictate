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
        XCTAssertEqual(state.step, .model)
    }

    func testPermissionSkipAllowsModelStep() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())

        state.skipPermissions()

        XCTAssertTrue(state.canContinue)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .model)
    }

    func testModelRequiresReadyState() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())
        state.skipPermissions()
        XCTAssertTrue(state.advance())

        XCTAssertFalse(state.canContinue)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .model)

        state.updateEngineReady(true)

        XCTAssertTrue(state.canContinue)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .keysAndAgent)
    }

    func testBackNavigationPreservesSatisfiedGates() {
        var state = OnboardingFlowState()
        XCTAssertTrue(state.advance())
        state.skipPermissions()
        XCTAssertTrue(state.advance())
        state.updateEngineReady(true)
        XCTAssertTrue(state.advance())

        state.goBack()
        XCTAssertEqual(state.step, .model)
        XCTAssertTrue(state.canContinue)

        state.goBack()
        XCTAssertEqual(state.step, .permissions)
        XCTAssertTrue(state.canContinue)
    }
}
