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

    private static let everySelection: [OnboardingJobs] = [
        OnboardingJobs(dictation: true, meetings: true),
        OnboardingJobs(dictation: true, meetings: false),
        OnboardingJobs(dictation: false, meetings: true),
        OnboardingJobs(dictation: false, meetings: false),
        OnboardingJobs(
            scope: .meetingsOnly,
            dictation: false,
            meetings: true
        ),
    ]

    /// Length, not punctuation: "hold fn, talk, let go. the text lands where
    /// your cursor is." is two sentences and one idea. Seventy characters is
    /// about two lines in a window this narrow.
    func testEveryScreenSaysWhyBriefly() {
        for jobs in Self.everySelection {
            for step in OnboardingStep.allCases {
                let reason = step.reason(for: jobs)
                XCTAssertFalse(reason.isEmpty, "\(step) \(jobs)")
                XCTAssertLessThanOrEqual(
                    reason.count,
                    70,
                    "\(step): \"\(reason)\" is long enough to be its own screen"
                )
                XCTAssertFalse(
                    step.title(for: jobs).isEmpty,
                    "\(step) \(jobs)"
                )
            }
        }
    }

    /// The button on the first card carries a price, so it is allowed to be
    /// longer than the two words that follow it.
    func testTheButtonsAreShortExceptTheOneThatQuotesAPrice() {
        for jobs in Self.everySelection {
            XCTAssertLessThanOrEqual(
                OnboardingStep.hello.actionTitle(for: jobs).count,
                34,
                "\(jobs)"
            )
            for step in [OnboardingStep.model, .permissions] {
                let title = step.actionTitle(for: jobs)
                XCTAssertFalse(title.isEmpty, "\(step)")
                XCTAssertLessThanOrEqual(title.count, 24, "\(step)")
            }
        }
    }

    /// One model or two — the plural is the tell that both jobs are ticked.
    func testTheModelScreenCountsTheModels() {
        XCTAssertEqual(
            OnboardingStep.model.title(
                for: OnboardingJobs(dictation: true, meetings: true)
            ),
            "the speech models"
        )
        XCTAssertEqual(
            OnboardingStep.model.title(
                for: OnboardingJobs(dictation: true, meetings: false)
            ),
            "the speech model"
        )
        XCTAssertEqual(
            OnboardingStep.model.title(
                for: OnboardingJobs(dictation: false, meetings: true)
            ),
            "the speech model"
        )
    }

    /// Microphone is both jobs'; accessibility is dictation's and system
    /// audio is meetings'. So two, three, or two again.
    func testThePermissionScreenCountsWhatEachJobNeeds() {
        let both = OnboardingJobs(dictation: true, meetings: true)
        XCTAssertEqual(
            both.permissions,
            ["microphone", "accessibility", "system audio"]
        )
        XCTAssertEqual(
            OnboardingStep.permissions.title(for: both),
            "three permissions"
        )

        let dictation = OnboardingJobs(dictation: true, meetings: false)
        XCTAssertEqual(dictation.permissions, ["microphone", "accessibility"])
        XCTAssertEqual(
            OnboardingStep.permissions.title(for: dictation),
            "two permissions"
        )

        let meetings = OnboardingJobs(dictation: false, meetings: true)
        XCTAssertEqual(meetings.permissions, ["microphone", "system audio"])
        XCTAssertEqual(
            OnboardingStep.permissions.title(for: meetings),
            "two permissions"
        )
    }

    /// Reopened from `record a meeting`, this window is one errand, and says
    /// so instead of introducing an app you already have.
    func testMeetingsOnlySaysHelloAsAnErrand() {
        let meetingsOnly = OnboardingJobs(
            scope: .meetingsOnly,
            dictation: false,
            meetings: true
        )

        XCTAssertEqual(
            OnboardingStep.hello.title(for: meetingsOnly),
            "set up meeting recording"
        )
        XCTAssertEqual(
            OnboardingStep.hello.actionTitle(for: meetingsOnly),
            "set up meeting recording (~2.9 gb)"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.title(for: meetingsOnly),
            "two permissions"
        )
    }

    /// Nothing downloads before the click, so the click says what it will
    /// cost — and reprices the moment a tick changes.
    func testTheButtonPricesWhatTheClickWillDownload() {
        XCTAssertEqual(
            OnboardingStep.hello.actionTitle(
                for: OnboardingJobs(dictation: true, meetings: true)
            ),
            "set up andrew dictate (~3.3 gb)"
        )
        XCTAssertEqual(
            OnboardingStep.hello.actionTitle(
                for: OnboardingJobs(dictation: true, meetings: false)
            ),
            "set up andrew dictate (~460 mb)"
        )
        XCTAssertEqual(
            OnboardingStep.hello.actionTitle(
                for: OnboardingJobs(dictation: false, meetings: true)
            ),
            "set up andrew dictate (~2.9 gb)"
        )
        XCTAssertEqual(
            OnboardingStep.hello.actionTitle(
                for: OnboardingJobs(dictation: false, meetings: false)
            ),
            "set up andrew dictate",
            "nothing ticked is nothing to price"
        )
    }
}
