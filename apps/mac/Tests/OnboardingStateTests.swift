import XCTest

final class OnboardingStateTests: XCTestCase {
    /// Both jobs are ticked out of the box, so a test about the dictation
    /// half has to say so — otherwise it is testing both.
    private func dictationOnly() -> OnboardingState {
        var state = OnboardingState()
        XCTAssertTrue(state.setMeetingsSelected(false))
        return state
    }

    private func meetingsOnlyByChoice() -> OnboardingState {
        var state = OnboardingState()
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

    // MARK: - both jobs are the default

    func testBothJobsAreOnUntilSomebodySaysOtherwise() {
        let state = OnboardingState()

        XCTAssertEqual(state.scope, .everything)
        XCTAssertTrue(state.dictationSelected)
        XCTAssertTrue(state.meetingsSelected)
        XCTAssertEqual(state.jobs.downloadSize, "~1.1 gb")
    }

    func testBothJobsNeedAllFiveRows() {
        var state = OnboardingState()
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
            var state = OnboardingState()
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
        XCTAssertTrue(state.setMeetingsSelected(false))

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
        XCTAssertTrue(state.setMeetingsSelected(false))
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

    /// The meeting model is a download too, so it earns the panel on its own.
    func testWhileYouWaitAppearsForAPendingMeetingModel() {
        var state = meetingsOnlyByChoice()
        state.updateMicrophoneStatus(.ready)
        state.updateMeetingModelStatus(.pending)

        XCTAssertTrue(state.consentToSetup())
        XCTAssertTrue(state.whileYouWaitVisible)
    }
}
