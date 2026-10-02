import XCTest

/// What each phase of a meeting looks like where it is shown: the menu's
/// first line, the badge's mark and what VoiceOver says for it. Plain
/// values in, so every phase can be held against each without a meeting
/// behind it.
final class MeetingPhaseLooksTests: XCTestCase {
    // MARK: - the menu's first line

    func testTheMenuSaysEachPhaseInWords() {
        let elapsed = Duration.seconds(12 * 60 + 34)
        XCTAssertNil(MeetingPhase.idle.menuLine(elapsed: elapsed))
        XCTAssertEqual(MeetingPhase.gettingReady.menuLine(elapsed: elapsed), "getting ready…")
        XCTAssertEqual(MeetingPhase.recording.menuLine(elapsed: elapsed), "recording · 12:34")
        XCTAssertEqual(
            MeetingPhase.problem(.cannotHearYourMic("MacBook Pro Microphone")).menuLine(elapsed: elapsed),
            "can't hear your mic — macbook pro microphone")
        XCTAssertEqual(
            MeetingPhase.writingOut(recovering: nil).menuLine(elapsed: elapsed),
            "writing it out…")
        XCTAssertEqual(
            MeetingPhase.writingOut(recovering: "zoom").menuLine(elapsed: elapsed),
            "writing out an unsaved zoom recording…")
    }

    /// A problem's line names it, in the words the lamp used when it began.
    func testAProblemsLineNamesTheProblem() {
        let lines: [(MeetingSession.Problem, String)] = [
            (.cannotHearTheCall, "can't hear the call — still recording your side"),
            (.cannotHearAnything, "can't hear the call or your mic — still trying"),
            (.cannotHearYourMic("Yeti"), "can't hear your mic — yeti"),
            (.cannotHearYourMic(nil), "can't hear your mic"),
            (.cannotSaveTheAudio, "can't save the audio — still transcribing"),
            (.diskNearlyFull, "disk nearly full"),
        ]
        for (problem, line) in lines {
            XCTAssertEqual(MeetingPhase.problem(problem).menuLine(elapsed: .seconds(5)), line)
            XCTAssertEqual(MeetingEvent.problemBegan(problem).hudText, line)
        }
    }

    // MARK: - the badge

    func testTheBadgeWearsEachPhase() {
        let worn: [(MeetingPhase, BadgeLook.Meeting)] = [
            (.idle, .none),
            (.gettingReady, .gettingReady),
            (.recording, .recording),
            (.problem(.diskNearlyFull), .problem),
            // the file is not on disk yet: the badge is still busy with a
            // meeting.
            (.writingOut(recovering: nil), .gettingReady),
            (.writingOut(recovering: "zoom"), .gettingReady),
        ]
        for (phase, meeting) in worn {
            XCTAssertEqual(BadgeLook.Meeting(phase, callNotRecorded: false), meeting, "\(phase)")
        }
    }

    /// A call nobody records is shown only when no meeting is: one being
    /// recorded or written out is the meeting the badge is about.
    func testACallNobodyRecordsIsShownOnlyWithNoMeeting() {
        XCTAssertEqual(BadgeLook.Meeting(.idle, callNotRecorded: true), .callNotRecorded)
        for phase in [
            MeetingPhase.gettingReady, .recording, .problem(.diskNearlyFull),
            .writingOut(recovering: nil),
        ] {
            XCTAssertNotEqual(
                BadgeLook.Meeting(phase, callNotRecorded: true), .callNotRecorded, "\(phase)")
        }
    }

    // MARK: - VoiceOver

    /// The badge carries a mark and nothing else; VoiceOver gets the
    /// phase in words, after the app's name.
    func testVoiceOverSaysEachPhase() {
        XCTAssertNil(MeetingPhase.idle.spoken)
        XCTAssertEqual(MeetingPhase.gettingReady.spoken, "getting ready to record a meeting")
        XCTAssertEqual(MeetingPhase.recording.spoken, "recording a meeting")
        XCTAssertEqual(
            MeetingPhase.problem(.cannotHearYourMic("MacBook Pro Microphone")).spoken,
            "recording a meeting, can't hear your mic — macbook pro microphone")
        XCTAssertEqual(MeetingPhase.writingOut(recovering: nil).spoken, "writing out a meeting")
        XCTAssertEqual(
            MeetingPhase.writingOut(recovering: "zoom").spoken,
            "writing out an unsaved zoom recording")
    }
}
