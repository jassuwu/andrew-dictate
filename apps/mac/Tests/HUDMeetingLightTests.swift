import XCTest

/// the lamp while a meeting records (ticket 28): a full-screen call hides the
/// menu bar, so the lamp keeps a low light the whole time, quieter than a
/// take and deaf to the voices in the room.
final class HUDMeetingLightTests: XCTestCase {
    private func stage(
        _ state: HUDLampState = .idle,
        hasFeedback: Bool = false,
        isOnboarding: Bool = false,
        prewarmPresentsHUD: Bool = true,
        meetingLight: HUDMeetingLight
    ) -> HUDStage {
        HUDPresentation.stage(
            state: state,
            hasFeedback: hasFeedback,
            isOnboarding: isOnboarding,
            prewarmPresentsHUD: prewarmPresentsHUD,
            meetingLight: meetingLight
        )
    }

    func testRecordingAMeetingKeepsTheLampLit() {
        let light = HUDPresentation.meetingLight(
            HUDMeetingFacts(isRecording: true)
        )

        XCTAssertEqual(light, .steady)
        XCTAssertEqual(stage(meetingLight: light), .meeting(.steady))
    }

    /// until the tap has heard the start sound nothing is trusted, so the
    /// lamp wears the ember a take wears before its mic is heard.
    func testItsFirstMomentsWearTheEmber() {
        let light = HUDPresentation.meetingLight(
            HUDMeetingFacts(isRecording: true, isProvingItCanHear: true)
        )

        XCTAssertEqual(light, .ember)
        XCTAssertEqual(stage(meetingLight: light), .meeting(.ember))
    }

    /// a sentence or a question takes the stage as it always has, and the
    /// light is back the moment it leaves.
    func testAPillTakesTheStageAndTheLightComesBackAfter() {
        for light in [HUDMeetingLight.ember, .steady] {
            XCTAssertEqual(
                stage(hasFeedback: true, meetingLight: light),
                .pill
            )
            XCTAssertEqual(
                stage(hasFeedback: false, meetingLight: light),
                .meeting(light)
            )
        }
    }

    /// the meeting stopping puts the light out the way a take's goes: the
    /// cool-out, and the panel stays up for it. it holds until whoever
    /// timed it says it is done; a meeting starting again lights it.
    func testStoppingCoolsTheLightOut() {
        let stopped = HUDMeetingFacts()

        for lit in [HUDMeetingLight.ember, .steady] {
            XCTAssertEqual(
                HUDPresentation.meetingLight(stopped, after: lit),
                .coolingOut
            )
        }
        XCTAssertEqual(
            HUDPresentation.meetingLight(stopped, after: .coolingOut),
            .coolingOut
        )
        XCTAssertEqual(
            HUDPresentation.meetingLight(stopped, after: .off),
            .off
        )
        XCTAssertEqual(
            HUDPresentation.meetingLight(
                HUDMeetingFacts(isRecording: true, isProvingItCanHear: true),
                after: .coolingOut
            ),
            .ember
        )
        XCTAssertEqual(
            stage(meetingLight: .coolingOut),
            .meeting(.coolingOut)
        )
    }

    /// with no meeting on, the stage is what it was before meetings had a
    /// light: a take's lamp from the press to the cool-out, an unasked
    /// warm-up showing nothing.
    func testADictationIsUnaffectedWhenNoMeetingIsOn() {
        XCTAssertEqual(stage(.idle, meetingLight: .off), .nothing)
        XCTAssertEqual(
            stage(.prewarming, prewarmPresentsHUD: false, meetingLight: .off),
            .nothing
        )
        XCTAssertEqual(
            stage(.prewarming, prewarmPresentsHUD: true, meetingLight: .off),
            .dictation
        )
        for state in [HUDLampState.recording, .transcribing] {
            XCTAssertEqual(stage(state, meetingLight: .off), .dictation)
        }
    }

    /// a take is allowed while the meeting proves it can hear, and looks
    /// like any take. the warm-up nobody asked for still shows nothing of
    /// its own, so the meeting keeps the lamp through it.
    func testATakeOutranksTheMeetingAndAnUnaskedWarmUpDoesNot() {
        for light in [HUDMeetingLight.ember, .steady, .coolingOut] {
            for state in [HUDLampState.recording, .transcribing] {
                XCTAssertEqual(stage(state, meetingLight: light), .dictation)
            }
            XCTAssertEqual(
                stage(.prewarming, prewarmPresentsHUD: true, meetingLight: light),
                .dictation
            )
            XCTAssertEqual(
                stage(.prewarming, prewarmPresentsHUD: false, meetingLight: light),
                .meeting(light)
            )
            XCTAssertEqual(
                stage(isOnboarding: true, meetingLight: light),
                .nothing
            )
        }
    }

    /// getting ready to record (nothing says so yet: the input waits for
    /// the ticket that has a reason to) wears the same ember as the first
    /// moments, recording or not.
    func testGettingReadyWearsTheEmber() {
        XCTAssertEqual(
            HUDPresentation.meetingLight(HUDMeetingFacts(isGettingReady: true)),
            .ember
        )
        XCTAssertEqual(
            HUDPresentation.meetingLight(
                HUDMeetingFacts(isRecording: true, isGettingReady: true)
            ),
            .ember
        )
    }

    /// a problem (nothing says so yet either) is the attention colour,
    /// steady, over every other look a meeting has: a meeting that is not
    /// hearing must never wear the light of one that is. with no meeting
    /// on it lights nothing, so a problem left set cannot hold the lamp on.
    func testAProblemWearsTheAttentionColourWhileTheMeetingIsOn() {
        for facts in [
            HUDMeetingFacts(isRecording: true, hasProblem: true),
            HUDMeetingFacts(
                isRecording: true,
                isProvingItCanHear: true,
                hasProblem: true
            ),
            HUDMeetingFacts(isGettingReady: true, hasProblem: true),
        ] {
            XCTAssertEqual(HUDPresentation.meetingLight(facts), .problem)
            XCTAssertEqual(stage(meetingLight: .problem), .meeting(.problem))
        }
        XCTAssertEqual(
            HUDPresentation.meetingLight(HUDMeetingFacts(hasProblem: true)),
            .off
        )
        XCTAssertEqual(
            HUDPresentation.meetingLight(
                HUDMeetingFacts(hasProblem: true),
                after: .problem
            ),
            .coolingOut
        )
    }
}

/// who can see the panel. a screen share, a recording or a screenshot sees a
/// window unless it is excluded from capture, and while a meeting is on the
/// people on the call must not see the light, or any pill about it.
extension HUDMeetingLightTests {
    private func hides(
        _ light: HUDMeetingLight = .off,
        meetingPillIsUp: Bool = false,
        isHiddenNow: Bool = false,
        isOnScreen: Bool = false
    ) -> Bool {
        HUDPresentation.hidesFromCapture(
            meetingLight: light,
            meetingPillIsUp: meetingPillIsUp,
            isHiddenNow: isHiddenNow,
            isOnScreen: isOnScreen
        )
    }

    func testThePanelIsHiddenFromCaptureWhileAMeetingIsOn() {
        for light in [
            HUDMeetingLight.ember,
            .steady,
            .problem,
            .coolingOut,
        ] {
            XCTAssertTrue(hides(light), "\(light)")
            XCTAssertTrue(hides(light, isOnScreen: true), "\(light)")
        }
    }

    /// the reminder, the stop question, the nudge, `writing it out…`,
    /// `saved`: every pill about a meeting, recording or not.
    func testAPillAboutAMeetingIsHiddenFromCapture() {
        XCTAssertTrue(hides(meetingPillIsUp: true))
        XCTAssertTrue(hides(meetingPillIsUp: true, isOnScreen: true))
    }

    /// dictation's lamp and pills stay in a screenshot, as they always
    /// have: that is how a bug report shows one.
    func testADictationIsSeenByCaptureWhenNoMeetingIsInvolved() {
        XCTAssertFalse(hides())
        XCTAssertFalse(hides(isOnScreen: true))
        // hidden last time and gone since: the next take is seen.
        XCTAssertFalse(hides(isHiddenNow: true, isOnScreen: false))
    }

    /// the panel never comes back into a capture while it is on screen: a
    /// take right after a meeting's pill stays hidden until the panel goes,
    /// so nothing on it flickers into a share mid-sentence.
    func testThePanelNeverComesBackIntoACaptureWhileItIsOnScreen() {
        XCTAssertTrue(hides(isHiddenNow: true, isOnScreen: true))
    }
}
