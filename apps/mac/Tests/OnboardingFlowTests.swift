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

    /// Until the consent click there is nothing behind the later screens —
    /// no download asked for, and a "done" button that would end setup on a
    /// mac where nothing had been set up.
    func testYouCannotJumpAheadBeforeConsenting() {
        let flow = OnboardingFlow()

        XCTAssertTrue(flow.canJump(to: .hello, consented: false))
        XCTAssertFalse(flow.canJump(to: .model, consented: false))
        XCTAssertFalse(flow.canJump(to: .permissions, consented: false))

        for step in OnboardingStep.allCases {
            XCTAssertTrue(flow.canJump(to: step, consented: true))
        }
    }

    /// A revoked grant opens on the screen that is actually broken.
    func testSetupCanOpenOnTheScreenThatIsBroken() {
        let flow = OnboardingFlow(step: .permissions)

        XCTAssertEqual(flow.step, .permissions)
        XCTAssertFalse(flow.canGoForward)
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
        OnboardingJobs(
            scope: .permissionsOnly,
            dictation: true,
            meetings: false
        ),
    ]

    private static let everyVerdict: [OnboardingVerdict] = [
        .ready,
        .downloading,
        .incomplete,
    ]

    /// Length, not punctuation: "hold fn, talk, let go. the text lands where
    /// your cursor is." is two sentences and one idea. Seventy characters is
    /// about two lines in a window this narrow.
    func testEveryScreenSaysWhyBriefly() {
        for jobs in Self.everySelection {
            // the hello line names the bound key, so the longest binding
            // has to fit too — "right ⌥" is the one that tests the ceiling.
            for key in HotkeyBinding.supported.map(\.displayName) {
                for verdict in Self.everyVerdict {
                    for step in OnboardingStep.allCases {
                        let reason = step.reason(
                            for: jobs,
                            key: key,
                            verdict: verdict
                        )
                        XCTAssertFalse(reason.isEmpty, "\(step) \(jobs)")
                        XCTAssertLessThanOrEqual(
                            reason.count,
                            70,
                            "\(step): \"\(reason)\" is long enough to be its own screen"
                        )
                        XCTAssertFalse(
                            step.title(for: jobs, verdict: verdict).isEmpty,
                            "\(step) \(jobs)"
                        )
                    }
                }
            }
        }
    }

    /// The one line that ever said `fn` out loud now reads the binding, so
    /// setup cannot tell you to hold a key you replaced.
    func testTheFirstScreenNamesTheKeyYouActuallyHave() {
        let jobs = OnboardingJobs(dictation: true, meetings: false)

        XCTAssertEqual(
            OnboardingStep.hello.reason(for: jobs, key: "fn"),
            "hold fn, talk, let go. the text lands where your cursor is."
        )
        XCTAssertEqual(
            OnboardingStep.hello.reason(for: jobs, key: "right ⌥"),
            "hold right ⌥, talk, let go. the text lands where your cursor is."
        )
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
            for verdict in Self.everyVerdict {
                for step in [OnboardingStep.model, .permissions] {
                    let title = step.actionTitle(for: jobs, verdict: verdict)
                    XCTAssertFalse(title.isEmpty, "\(step) \(verdict)")
                    XCTAssertLessThanOrEqual(
                        title.count,
                        24,
                        "\(step) \(verdict)"
                    )
                }
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

    /// Reopened because macOS dropped a grant, the card says so — it does
    /// not introduce an app you have been using for weeks.
    func testPermissionsOnlySaysWhichSwitchWentOff() {
        let permissionsOnly = OnboardingJobs(
            scope: .permissionsOnly,
            dictation: true,
            meetings: false
        )

        XCTAssertEqual(
            OnboardingStep.permissions.title(for: permissionsOnly),
            "say yes again"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.reason(
                for: permissionsOnly,
                key: "fn"
            ),
            "already set up — macos dropped a permission. nothing to download."
        )
        XCTAssertEqual(
            OnboardingStep.permissions.title(
                for: permissionsOnly,
                verdict: .ready
            ),
            "ready",
            "a grant that came back is an arrival like any other"
        )
    }

    /// Pressed `record a meeting ▸ zoom` and sat through the download: the
    /// last button names the errand rather than saying "done" and dropping
    /// it. While the model is still coming down there is nothing to promise.
    func testTheLastButtonNamesTheMeetingYouAskedFor() {
        var meetingsOnly = OnboardingJobs(
            scope: .meetingsOnly,
            dictation: false,
            meetings: true
        )

        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: meetingsOnly,
                verdict: .ready
            ),
            "done",
            "no errand, no promise"
        )

        meetingsOnly.meetingApp = "zoom"
        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: meetingsOnly,
                verdict: .ready
            ),
            "record zoom"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: meetingsOnly,
                verdict: .downloading
            ),
            "done",
            "a button must not promise a recording it cannot start"
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

    // MARK: - the last card says what it can keep

    /// "done" is a claim. A card with a permission missing has nothing to
    /// claim, so it offers the exit instead.
    func testTheLastButtonOnlyClaimsDoneWhenSomethingIsDone() {
        let both = OnboardingJobs(dictation: true, meetings: true)
        let meetingsOnly = OnboardingJobs(
            scope: .meetingsOnly,
            dictation: false,
            meetings: true
        )

        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(for: both, verdict: .ready),
            "start dictating"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: meetingsOnly,
                verdict: .ready
            ),
            "done",
            "a meetings-only setup is never told to hold a key"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: both,
                verdict: .downloading
            ),
            "done"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.actionTitle(
                for: both,
                verdict: .incomplete
            ),
            "close"
        )
    }

    func testTheReadyCardIsTitledReadyAndSaysWhyItIsOver() {
        let dictation = OnboardingJobs(dictation: true, meetings: false)
        let meetingsOnly = OnboardingJobs(
            scope: .meetingsOnly,
            dictation: false,
            meetings: true
        )

        XCTAssertEqual(
            OnboardingStep.permissions.title(for: dictation, verdict: .ready),
            "ready"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.title(
                for: dictation,
                verdict: .downloading
            ),
            "two permissions",
            "a download is not an arrival"
        )
        XCTAssertEqual(
            OnboardingStep.permissions.reason(
                for: dictation,
                key: "fn",
                verdict: .ready
            ),
            "that's everything macos had to say yes to."
        )
        XCTAssertEqual(
            OnboardingStep.permissions.reason(
                for: meetingsOnly,
                key: "fn",
                verdict: .ready
            ),
            "that's everything. your mic is you, their app is them."
        )
    }
}
