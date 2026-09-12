import XCTest

final class OnboardingStateTests: XCTestCase {
    /// Dictation alone is the shipped default, so this is a bare state.
    private func dictationOnly() -> OnboardingState {
        OnboardingState()
    }

    /// Meetings are offered, not assumed: a test about them has to tick the
    /// row the way a user would.
    private func bothJobs() -> OnboardingState {
        var state = OnboardingState()
        XCTAssertTrue(state.setMeetingsSelected(true))
        return state
    }

    private func meetingsOnlyByChoice() -> OnboardingState {
        var state = OnboardingState()
        XCTAssertTrue(state.setMeetingsSelected(true))
        XCTAssertTrue(state.setDictationSelected(false))
        return state
    }

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

    // MARK: - dictation is the default; meetings are offered

    func testOnlyDictationIsOnUntilYouAskForMeetings() {
        let state = OnboardingState()

        XCTAssertEqual(state.scope, .everything)
        XCTAssertTrue(state.dictationSelected)
        XCTAssertFalse(state.meetingsSelected)
        XCTAssertEqual(state.jobs.downloadSize, "~460 mb")
        XCTAssertEqual(
            state.jobs.permissions,
            ["microphone", "accessibility"]
        )
    }

    func testTickingMeetingsRestoresTheOldDefaultByteForByte() {
        var state = OnboardingState()

        XCTAssertTrue(state.setMeetingsSelected(true))

        XCTAssertTrue(state.dictationSelected)
        XCTAssertTrue(state.meetingsSelected)
        XCTAssertEqual(state.jobs.downloadSize, "~3.3 gb")
    }

    func testBothJobsNeedAllFiveRows() {
        var state = bothJobs()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)

        XCTAssertFalse(
            state.autoFinishArmed,
            "the dictation three are not the whole checklist any more"
        )

        state.updateSystemAudioStatus(.ready)
        XCTAssertFalse(state.autoFinishArmed)

        state.updateMeetingModelStatus(.ready)
        XCTAssertTrue(state.autoFinishArmed)
        XCTAssertTrue(state.finishAutomatically())
    }

    /// Each of the five rows, dropped one at a time: any one of them missing
    /// keeps the card open.
    func testAnyMissingRowOfEitherJobDisarmsAutoFinish() {
        let drops: [(String, (inout OnboardingState) -> Void)] = [
            ("microphone", { $0.updateMicrophoneStatus(.pending) }),
            ("accessibility", { $0.updateAccessibility(granted: false) }),
            ("model", { $0.updateModelStatus(.pending) }),
            ("system audio", { $0.updateSystemAudioStatus(.pending) }),
            ("meeting model", { $0.updateMeetingModelStatus(.pending) }),
        ]

        for (name, drop) in drops {
            var state = bothJobs()
            state.updateMicrophoneStatus(.ready)
            state.updateAccessibility(granted: true)
            state.updateModelStatus(.ready)
            state.updateSystemAudioStatus(.ready)
            state.updateMeetingModelStatus(.ready)
            XCTAssertTrue(state.autoFinishArmed, name)

            drop(&state)

            XCTAssertFalse(state.autoFinishArmed, name)
        }
    }

    // MARK: - one job, one checklist

    func testDictationOnlyStillArmsOnTheOldThree() {
        for microphoneReady in [false, true] {
            for accessibilityReady in [false, true] {
                for modelReady in [false, true] {
                    var state = dictationOnly()
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

    /// The meeting rows are not the dictation rows: no accessibility, no
    /// dictation model, and system audio instead.
    func testMeetingsOnlyArmsOnMicSystemAudioAndItsOwnModel() {
        var state = meetingsOnlyByChoice()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.ready)
        state.updateSystemAudioStatus(.ready)
        state.updateMeetingModelStatus(.ready)

        XCTAssertTrue(state.autoFinishArmed)
        XCTAssertEqual(
            state.accessibilityStatus,
            .pending,
            "meetings never ask for accessibility, so it is never demanded"
        )
        XCTAssertEqual(state.modelStatus, .pending)
        XCTAssertTrue(state.finishAutomatically())
    }

    func testNoJobSelectedIsNeverArmed() {
        var state = OnboardingState()
        XCTAssertTrue(state.setDictationSelected(false))
        XCTAssertFalse(state.meetingsSelected)

        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)
        state.updateSystemAudioStatus(.ready)
        state.updateMeetingModelStatus(.ready)

        XCTAssertFalse(state.autoFinishArmed)
        XCTAssertFalse(state.finishAutomatically())
        XCTAssertEqual(state.jobs.downloadSize, "")
    }

    // MARK: - the ticks are asked once

    func testTicksAreRefusedOnceSetupHasStarted() {
        var state = OnboardingState()
        XCTAssertTrue(state.consentToSetup())

        XCTAssertFalse(state.setMeetingsSelected(true))
        XCTAssertFalse(state.setDictationSelected(false))
        XCTAssertTrue(state.dictationSelected)
        XCTAssertFalse(state.meetingsSelected)
    }

    func testMeetingsOnlyScopeForcesTheJobsAndRefusesChanges() {
        var state = OnboardingState(scope: .meetingsOnly)

        XCTAssertFalse(state.dictationSelected)
        XCTAssertTrue(state.meetingsSelected)

        XCTAssertFalse(state.setDictationSelected(true))
        XCTAssertFalse(state.setMeetingsSelected(false))
        XCTAssertFalse(state.dictationSelected)
        XCTAssertTrue(state.meetingsSelected)
    }

    /// The errand only reaches the button once its model is on disk.
    func testTheErrandIsOnlyOfferedOnceTheMeetingModelIsReady() {
        var state = OnboardingState(scope: .meetingsOnly)
        state.updateMeetingErrand(app: "zoom")

        XCTAssertNil(state.jobs.meetingApp)

        state.updateMeetingModelStatus(.ready)
        XCTAssertEqual(state.jobs.meetingApp, "zoom")

        state.updateMeetingErrand(app: nil)
        XCTAssertNil(state.jobs.meetingApp)
    }

    // MARK: - a lost grant is one screen

    /// The upgrade-day reentry asks for the two grants dictation needs and
    /// nothing else: no jobs to pick, no meeting model, no price.
    func testPermissionsOnlyAsksForTheTwoGrantsAndRefusesTheTicks() {
        var state = OnboardingState(scope: .permissionsOnly)

        XCTAssertTrue(state.dictationSelected)
        XCTAssertFalse(state.meetingsSelected)
        XCTAssertEqual(
            state.jobs.permissions,
            ["microphone", "accessibility"]
        )

        XCTAssertFalse(state.setMeetingsSelected(true))
        XCTAssertFalse(state.setDictationSelected(false))
        XCTAssertTrue(state.dictationSelected)
        XCTAssertFalse(state.meetingsSelected)
    }

    /// Consent is given for that scope on arrival, which is what turns the
    /// missing row into "open settings" instead of a dead "allow".
    func testPermissionsOnlyConsentDemandsTheMissingSwitch() {
        var state = OnboardingState(scope: .permissionsOnly)

        XCTAssertTrue(state.consentToSetup())
        state.updateAccessibility(granted: false)

        XCTAssertEqual(state.accessibilityStatus, .actionRequired)
    }

    func testMeetingsOnlyConsentDoesNotDemandAccessibility() {
        var state = OnboardingState(scope: .meetingsOnly)

        XCTAssertTrue(state.consentToSetup())

        XCTAssertEqual(state.accessibilityStatus, .pending)
    }

    // MARK: - the rest of the card

    func testDeniedMicrophoneKeepsCardOpenWithSettingsStatus() {
        var state = dictationOnly()
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
        var state = dictationOnly()
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
        var state = dictationOnly()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)
        XCTAssertTrue(state.autoFinishArmed)

        state.updateModelStatus(.actionRequired)

        XCTAssertFalse(state.autoFinishArmed)
        XCTAssertEqual(state.modelStatus, .actionRequired)
        XCTAssertEqual(state.completion, .pending)
    }

    func testWhileYouWaitAppearsAfterConsentAndStaysThroughReadiness() {
        var state = dictationOnly()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.pending)

        XCTAssertFalse(state.whileYouWaitVisible)
        XCTAssertTrue(state.consentToSetup())
        XCTAssertTrue(state.whileYouWaitVisible)

        state.updateModelStatus(.ready)

        XCTAssertTrue(state.whileYouWaitVisible)
        XCTAssertTrue(state.autoFinishArmed)
    }

    func testWhileYouWaitNeverAppearsWhenModelWasReadyAtConsent() {
        var state = dictationOnly()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)

        XCTAssertTrue(state.consentToSetup())
        XCTAssertFalse(state.whileYouWaitVisible)
        XCTAssertTrue(state.autoFinishArmed)
    }

    // MARK: - what the last card may claim

    func testEveryRowReadyIsTheOnlyReadyVerdict() {
        var state = bothJobs()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.ready)
        state.updateSystemAudioStatus(.ready)
        state.updateMeetingModelStatus(.ready)

        XCTAssertEqual(state.verdict, .ready)
        XCTAssertTrue(state.autoFinishArmed)
    }

    /// Grants in, bytes still arriving: a wait, not a failure. Closing the
    /// window does not stop the download, so the card may say so.
    func testGrantsInWithAModelComingDownIsADownloadingVerdict() {
        var state = dictationOnly()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.ready)
        state.updateAccessibility(granted: true)
        state.updateModelStatus(.pending)

        XCTAssertEqual(state.verdict, .downloading)
        XCTAssertFalse(state.autoFinishArmed)

        state.updateModelStatus(.ready)
        XCTAssertEqual(state.verdict, .ready)
    }

    func testTheMeetingModelEarnsTheSameDownloadingVerdict() {
        var state = meetingsOnlyByChoice()
        _ = state.consentToSetup()
        state.updateMicrophoneStatus(.ready)
        state.updateSystemAudioStatus(.ready)
        state.updateMeetingModelStatus(.inProgress)

        XCTAssertEqual(state.verdict, .downloading)
    }

    /// A missing permission is the one that means nothing is done — for
    /// either job, and even with every model already on disk.
    func testAMissingPermissionIsAlwaysIncomplete() {
        var dictation = dictationOnly()
        _ = dictation.consentToSetup()
        dictation.updateMicrophoneStatus(.ready)
        dictation.updateAccessibility(granted: false)
        dictation.updateModelStatus(.ready)
        XCTAssertEqual(dictation.verdict, .incomplete)

        var meetings = meetingsOnlyByChoice()
        _ = meetings.consentToSetup()
        meetings.updateMicrophoneStatus(.ready)
        meetings.updateSystemAudioStatus(.actionRequired)
        meetings.updateMeetingModelStatus(.ready)
        XCTAssertEqual(meetings.verdict, .incomplete)

        var both = bothJobs()
        _ = both.consentToSetup()
        both.updateMicrophoneStatus(.actionRequired)
        both.updateAccessibility(granted: true)
        both.updateModelStatus(.ready)
        both.updateSystemAudioStatus(.ready)
        both.updateMeetingModelStatus(.ready)
        XCTAssertEqual(both.verdict, .incomplete)
    }

    func testNoJobSelectedCanNeverBeReady() {
        var state = OnboardingState()
        XCTAssertTrue(state.setDictationSelected(false))
        state.updateMicrophoneStatus(.ready)

        XCTAssertEqual(state.verdict, .incomplete)
    }

    /// The meeting model is a download too, so it earns the panel on its own.
    func testWhileYouWaitAppearsForAPendingMeetingModel() {
        var state = meetingsOnlyByChoice()
        state.updateMicrophoneStatus(.ready)
        state.updateMeetingModelStatus(.pending)

        XCTAssertTrue(state.consentToSetup())
        XCTAssertTrue(state.whileYouWaitVisible)
    }
}
