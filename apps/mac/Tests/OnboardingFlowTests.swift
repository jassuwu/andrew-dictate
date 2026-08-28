import XCTest

final class OnboardingFlowTests: XCTestCase {
    func testItStartsBySayingHello() {
        XCTAssertEqual(OnboardingFlow().step, .hello)
    }

    func testItWalksForwardsOneScreenAtATime() {
        var flow = OnboardingFlow()

        flow.advance()
        XCTAssertEqual(flow.step, .microphone)
        flow.advance()
        XCTAssertEqual(flow.step, .accessibility)
        flow.advance()
        XCTAssertEqual(flow.step, .model)
        flow.advance()
        XCTAssertEqual(flow.step, .ready)
    }

    func testItStopsAtTheEndRatherThanFallingOff() {
        var flow = OnboardingFlow()
        flow.jump(to: .ready)

        flow.advance()

        XCTAssertEqual(flow.step, .ready)
        XCTAssertTrue(flow.isLastStep)
    }

    /// Being able to retreat is what makes a stepped flow feel safe rather than
    /// like a trap — so back does not depend on the current step being done.
    func testYouCanAlwaysGoBackOnceYouHaveStarted() {
        var flow = OnboardingFlow()
        XCTAssertFalse(flow.canGoBack, "there is nothing behind hello")

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

    func testThePositionIsOneBasedSoItReadsAsThreeOfFive() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.position.index, 1)
        XCTAssertEqual(flow.position.total, 5)

        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.position.index, 3)
    }

    // MARK: - what each screen is waiting for

    func testEachPermissionScreenWaitsForItsOwnPermission() {
        var state = OnboardingState()
        var flow = OnboardingFlow()
        flow.jump(to: .microphone)

        XCTAssertFalse(flow.isSatisfied(by: state))
        state.updateMicrophoneStatus(.ready)
        XCTAssertTrue(flow.isSatisfied(by: state))

        flow.jump(to: .accessibility)
        XCTAssertFalse(
            flow.isSatisfied(by: state),
            "a granted microphone must not satisfy the accessibility screen"
        )
        state.updateAccessibility(granted: true)
        XCTAssertTrue(flow.isSatisfied(by: state))

        flow.jump(to: .model)
        XCTAssertFalse(flow.isSatisfied(by: state))
        state.updateModelStatus(.ready)
        XCTAssertTrue(flow.isSatisfied(by: state))
    }

    func testTheScreensThatOnlyTalkAreAlwaysSatisfied() {
        let state = OnboardingState()
        var flow = OnboardingFlow()

        XCTAssertTrue(flow.isSatisfied(by: state))
        flow.jump(to: .ready)
        XCTAssertTrue(flow.isSatisfied(by: state))
    }

    // MARK: - the copy

    /// The whole redesign in one assertion: one way out, on one screen.
    func testOnlyTheFirstScreenOffersAWayOut() {
        XCTAssertTrue(OnboardingStep.hello.offersSkip)
        for step in OnboardingStep.allCases where step != .hello {
            XCTAssertFalse(step.offersSkip, "\(step)")
        }
    }

    /// The constraint is length, not punctuation. "hold fn, talk, let go. the
    /// text lands where your cursor is." is two sentences and one idea, and
    /// squeezing it into one would read worse. Seventy characters is roughly
    /// two lines in a window this narrow — past that it stops being a screen
    /// with one thing on it.
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
