import XCTest

final class OnboardingFlowTests: XCTestCase {
    func testItStartsBySayingHello() {
        XCTAssertEqual(OnboardingFlow().step, .hello)
    }

    /// Three screens, not five. The three requirements are not three ideas:
    /// the model downloads in the background, and the two permissions are one
    /// question — what the app needs in order to work.
    func testThereAreThreeScreens() {
        XCTAssertEqual(OnboardingStep.allCases.count, 3)
        XCTAssertEqual(
            OnboardingStep.allCases,
            [.hello, .model, .permissions]
        )
    }

    func testItWalksForwardsAndStopsAtTheEnd() {
        var flow = OnboardingFlow()

        flow.advance()
        XCTAssertEqual(flow.step, .model)
        flow.advance()
        XCTAssertEqual(flow.step, .permissions)
        XCTAssertFalse(flow.canGoForward)

        flow.advance()
        XCTAssertEqual(flow.step, .permissions, "it must not fall off the end")
    }

    func testYouCanAlwaysGoBackOnceYouHaveStarted() {
        var flow = OnboardingFlow()
        XCTAssertFalse(flow.canGoBack)

        flow.advance()
        XCTAssertTrue(flow.canGoBack)
        flow.goBack()
        XCTAssertEqual(flow.step, .hello)
    }

    func testGoingBackFromTheFirstScreenDoesNothing() {
        var flow = OnboardingFlow()

        flow.goBack()

        XCTAssertEqual(flow.step, .hello)
    }

    /// Going back to check something should not mean walking the whole flow.
    func testAnyScreenIsReachableDirectly() {
        var flow = OnboardingFlow()

        flow.jump(to: .permissions)
        XCTAssertEqual(flow.step, .permissions)
        flow.jump(to: .hello)
        XCTAssertEqual(flow.step, .hello)
    }

    func testThePositionIsOneBasedSoItReadsAsTwoOfThree() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.position.index, 1)
        XCTAssertEqual(flow.position.total, 3)

        flow.advance()
        XCTAssertEqual(flow.position.index, 2)
    }

    // MARK: - the copy

    /// Length, not punctuation: "hold fn, talk, let go. the text lands where
    /// your cursor is." is two sentences and one idea. Seventy characters is
    /// about two lines in a window this narrow.
    func testEveryScreenSaysWhyBriefly() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.reason.isEmpty, "\(step)")
            XCTAssertLessThanOrEqual(
                step.reason.count,
                70,
                "\(step): \"\(step.reason)\" is long enough to be its own screen"
            )
            XCTAssertFalse(step.actionTitle.isEmpty, "\(step)")
            XCTAssertLessThanOrEqual(step.actionTitle.count, 24, "\(step)")
        }
    }
}
