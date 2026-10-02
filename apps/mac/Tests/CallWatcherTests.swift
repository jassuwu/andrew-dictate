import XCTest

final class CallWatcherTests: XCTestCase {
    private func watcher() -> CallWatcher {
        CallWatcher(startAfter: .seconds(3), endAfter: .seconds(30))
    }

    private func app(
        _ name: String,
        mic: Bool = true,
        audio: Bool = true
    ) -> CallWatcher.App {
        CallWatcher.App(name: name, holdsMic: mic, playsAudio: audio)
    }

    // MARK: - a call begins

    func testAMicAndAudioHeldForTheStartThresholdAreACall() {
        var watcher = watcher()
        let zoom = app("zoom")

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(2)), [])
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(3)),
            [.record("zoom")]
        )
    }

    /// Asking again every second for an hour is not a suggestion, it is a
    /// nag.
    func testTheRecordSuggestionIsMadeOnceForACall() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))

        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(3)),
            [.record("zoom")]
        )
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(4)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(5)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(3_600)), [])
    }

    /// Continuously means continuously: two seconds of both, a blip of one,
    /// and the three seconds start again.
    func testTheStartClockRestartsWhenEitherHalfDrops() {
        var watcher = watcher()
        let both = app("zoom")
        let micOnly = app("zoom", audio: false)
        let audioOnly = app("zoom", mic: false)

        _ = watcher.observe([both], isRecording: false, at: .seconds(0))
        _ = watcher.observe([both], isRecording: false, at: .seconds(2))
        XCTAssertEqual(watcher.observe([micOnly], isRecording: false, at: .seconds(3)), [])

        _ = watcher.observe([both], isRecording: false, at: .seconds(4))
        _ = watcher.observe([both], isRecording: false, at: .seconds(6))
        XCTAssertEqual(watcher.observe([audioOnly], isRecording: false, at: .seconds(7)), [])

        _ = watcher.observe([both], isRecording: false, at: .seconds(8))
        XCTAssertEqual(watcher.observe([both], isRecording: false, at: .seconds(10)), [])
        XCTAssertEqual(
            watcher.observe([both], isRecording: false, at: .seconds(11)),
            [.record("zoom")]
        )
    }

    /// Asking to record what is already being recorded would be a question
    /// with only one sensible answer.
    func testNothingIsSuggestedWhenARecordingIsAlreadyRunning() {
        var watcher = watcher()
        let zoom = app("zoom")

        XCTAssertEqual(watcher.observe([zoom], isRecording: true, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: true, at: .seconds(3)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: true, at: .seconds(10)), [])
    }

    // MARK: - what the watcher can be asked

    /// The recording's file is named after the call, so the app asks at the
    /// moment you press record.
    func testTheCurrentCallIsNamedFromTheMomentItBegins() {
        var watcher = watcher()
        let zoom = app("zoom")

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        XCTAssertNil(watcher.currentCall)

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    func testTheCurrentCallIsNamedWhetherOrNotItIsBeingRecorded() {
        var watcher = watcher()
        let meet = app("chrome")

        _ = watcher.observe([meet], isRecording: true, at: .seconds(0))
        _ = watcher.observe([meet], isRecording: true, at: .seconds(3))

        XCTAssertEqual(watcher.currentCall, "chrome")
    }

    /// The menu bar icon's third state: a call is on and nothing is catching
    /// it.
    func testACallWithNothingRecordingIsReportedAsUnrecorded() {
        var watcher = watcher()
        let zoom = app("zoom")

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        XCTAssertNil(watcher.unrecordedCall)

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        XCTAssertEqual(watcher.unrecordedCall, "zoom")
    }

    func testACallThatIsBeingRecordedIsNotReportedAsUnrecorded() {
        var watcher = watcher()
        let zoom = app("zoom")

        _ = watcher.observe([zoom], isRecording: true, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(3))

        XCTAssertNil(watcher.unrecordedCall)
    }

    /// The reply to the record suggestion is the user pressing record, and
    /// the icon should follow the moment they do.
    func testPressingRecordTurnsTheCallIntoARecordedOne() {
        var watcher = watcher()
        let zoom = app("zoom")

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        XCTAssertEqual(watcher.unrecordedCall, "zoom")

        _ = watcher.observe([zoom], isRecording: true, at: .seconds(5))
        XCTAssertNil(watcher.unrecordedCall)
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    // MARK: - a call ends

    /// The watcher only asks. If nobody answers, the recording stays on and
    /// nothing more is said about this call.
    func testACallThatEndsWhileRecordingSuggestsStopOnce() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(100))

        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(101)), [])
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(130)), [])
        XCTAssertEqual(
            watcher.observe([], isRecording: true, at: .seconds(131)),
            [.stop("zoom")]
        )
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(132)), [])
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(3_600)), [])
    }

    /// A pause in the audio, a dropped connection that comes back: either
    /// half returning inside the window is the same call, and every silence
    /// gets the whole window afresh.
    func testEitherHalfComingBackInsideTheEndThresholdKeepsTheCall() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(5))

        _ = watcher.observe([], isRecording: true, at: .seconds(100))
        let micBack = app("zoom", audio: false)
        XCTAssertEqual(watcher.observe([micBack], isRecording: true, at: .seconds(129)), [])

        _ = watcher.observe([], isRecording: true, at: .seconds(130))
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(159)), [])
        let audioBack = app("zoom", mic: false)
        XCTAssertEqual(watcher.observe([audioBack], isRecording: true, at: .seconds(160)), [])

        _ = watcher.observe([], isRecording: true, at: .seconds(161))
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(190)), [])
        XCTAssertEqual(
            watcher.observe([], isRecording: true, at: .seconds(191)),
            [.stop("zoom")]
        )
    }

    /// A participant who mutes still hears everyone else. Losing the mic
    /// alone is the most common thing that happens in a call.
    func testMutingDoesNotEndTheCall() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(5))

        let muted = app("zoom", mic: false, audio: true)
        XCTAssertEqual(watcher.observe([muted], isRecording: true, at: .seconds(100)), [])
        XCTAssertEqual(watcher.observe([muted], isRecording: true, at: .seconds(1_000)), [])
        XCTAssertEqual(watcher.observe([muted], isRecording: true, at: .seconds(5_000)), [])
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    /// Everyone else going quiet while you hold the mic open is a pause in a
    /// conversation, not the end of one.
    func testTheOtherSideGoingQuietDoesNotEndTheCall() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(5))

        let listening = app("zoom", mic: true, audio: false)
        XCTAssertEqual(watcher.observe([listening], isRecording: true, at: .seconds(100)), [])
        XCTAssertEqual(watcher.observe([listening], isRecording: true, at: .seconds(1_000)), [])
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    /// The list is meant to leave out an app that is doing neither, but an
    /// entry that says so anyway is not a reason to hold the call open.
    func testAnAppListedWhileDoingNothingCountsAsAbsent() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(5))

        let idle = app("zoom", mic: false, audio: false)
        XCTAssertEqual(watcher.observe([idle], isRecording: true, at: .seconds(100)), [])
        XCTAssertEqual(watcher.observe([idle], isRecording: true, at: .seconds(129)), [])
        XCTAssertEqual(
            watcher.observe([idle], isRecording: true, at: .seconds(130)),
            [.stop("zoom")]
        )
    }

    /// Nothing was recording, so there is nothing to stop; the call just
    /// stops being the current one.
    func testACallThatEndsWithNothingRecordingSuggestsNothing() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))

        XCTAssertEqual(watcher.observe([], isRecording: false, at: .seconds(100)), [])
        XCTAssertEqual(watcher.observe([], isRecording: false, at: .seconds(130)), [])
        XCTAssertEqual(watcher.observe([], isRecording: false, at: .seconds(131)), [])

        XCTAssertNil(watcher.currentCall)
        XCTAssertNil(watcher.unrecordedCall)
    }

    /// A call is a call once; the one after it is a new one, with its own
    /// threshold to cross and its own suggestion.
    func testTheNextCallStartsItsOwnThresholdAndSuggestsAgain() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([], isRecording: false, at: .seconds(100))
        _ = watcher.observe([], isRecording: false, at: .seconds(130))
        XCTAssertNil(watcher.currentCall)

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(200)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(202)), [])
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(203)),
            [.record("zoom")]
        )
    }

    // MARK: - stopping mid-call

    /// You pressed stop on purpose. Asking whether to record the same call
    /// you just stopped recording would be the app disagreeing with you.
    func testStoppingTheRecordingMidCallDoesNotSuggestRecordingAgain() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(10))

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(900)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(901)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(3_600)), [])
    }

    /// The same, for a call that began inside a recording and so was never
    /// asked about in the first place.
    func testStoppingARecordingThatHadTheCallInsideItDoesNotSuggestRecordingEither() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(3))

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(900)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(3_600)), [])
    }

    /// The icon is where the call shows up again: it is on, and nothing is
    /// recording it.
    func testACallWhoseRecordingStoppedIsReportedAsUnrecorded() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(3))
        XCTAssertNil(watcher.unrecordedCall)

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(900))
        XCTAssertEqual(watcher.unrecordedCall, "zoom")
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    /// There is nothing left to stop when the call finally ends.
    func testACallThatEndsAfterItsRecordingStoppedSuggestsNothing() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: true, at: .seconds(3))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(900))

        XCTAssertEqual(watcher.observe([], isRecording: false, at: .seconds(1_000)), [])
        XCTAssertEqual(watcher.observe([], isRecording: false, at: .seconds(1_030)), [])
    }

    // MARK: - saying no

    /// No is an answer. The call is still on, and the icon still says so,
    /// but nobody is asked again.
    func testDismissingTheSuggestionLeavesTheCallOnAndUnrecordedButSilent() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(3)),
            [.record("zoom")]
        )

        watcher.dismissRecordSuggestion()

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(4)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(600)), [])
        XCTAssertEqual(watcher.unrecordedCall, "zoom")
        XCTAssertEqual(watcher.currentCall, "zoom")
    }

    /// The no was about that call. Ending it and starting another is
    /// starting over.
    func testADismissalDoesNotOutliveItsCall() {
        var watcher = watcher()
        let zoom = app("zoom")
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        _ = watcher.observe([zoom], isRecording: false, at: .seconds(3))
        watcher.dismissRecordSuggestion()
        _ = watcher.observe([], isRecording: false, at: .seconds(100))
        _ = watcher.observe([], isRecording: false, at: .seconds(130))

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(200))
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(203)),
            [.record("zoom")]
        )
    }

    /// A pill tapped away after its call is over, or before any call, is not
    /// a no to the call that comes next.
    func testADismissalWithNoCallOnIsForgotten() {
        var watcher = watcher()
        let zoom = app("zoom")

        watcher.dismissRecordSuggestion()

        _ = watcher.observe([zoom], isRecording: false, at: .seconds(0))
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(3)),
            [.record("zoom")]
        )
    }

    // MARK: - recordings the watcher did not ask for

    /// Dictating notes to yourself, or a lecture: you started it, there was
    /// never a call, and the watcher has no business telling you to stop.
    func testARecordingStartedByHandWithNoCallNeverGetsAStopSuggestion() {
        var watcher = watcher()

        for second in stride(from: 0, through: 3_600, by: 60) {
            XCTAssertEqual(
                watcher.observe([], isRecording: true, at: .seconds(second)),
                []
            )
        }
        XCTAssertNil(watcher.currentCall)
    }

    /// Nor does a call app that only sounded like one: the mic and audio
    /// for a moment, or the mic alone, never made a call that could end.
    func testAnAppThatNeverQualifiedAsACallNeverEndsOne() {
        var watcher = watcher()
        let brief = app("chrome")
        let listening = app("chrome", audio: false)

        _ = watcher.observe([brief], isRecording: true, at: .seconds(0))
        _ = watcher.observe([brief], isRecording: true, at: .seconds(2))
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(3)), [])
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(60)), [])

        _ = watcher.observe([listening], isRecording: true, at: .seconds(100))
        _ = watcher.observe([listening], isRecording: true, at: .seconds(200))
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(201)), [])
        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(300)), [])
    }

    /// You pressed record first and the call started after. It is that
    /// recording's call now, and its end is worth a question.
    func testACallThatBeginsDuringAHandStartedRecordingEndsWithAStopSuggestion() {
        var watcher = watcher()
        let zoom = app("zoom")

        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: true, at: .seconds(60)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: true, at: .seconds(63)), [])
        XCTAssertEqual(watcher.currentCall, "zoom")

        XCTAssertEqual(watcher.observe([], isRecording: true, at: .seconds(1_000)), [])
        XCTAssertEqual(
            watcher.observe([], isRecording: true, at: .seconds(1_030)),
            [.stop("zoom")]
        )
    }

    /// A browser tab playing music is not a call, and neither is a podcast.
    func testAudioAloneIsNotACall() {
        var watcher = watcher()
        let music = app("chrome", mic: false, audio: true)

        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(60)), [])
        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(600)), [])
    }

    /// Dictation, a screen recorder and a voice memo all hold the mic without
    /// anyone being on a call.
    func testTheMicAloneIsNotACall() {
        var watcher = watcher()
        let listening = app("chrome", mic: true, audio: false)

        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(60)), [])
        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(600)), [])
    }
}
