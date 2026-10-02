import XCTest

/// What the pill asks about a meeting, and what each answer does (ADR
/// 0047). The app suggests; only the button acts, and it does what the menu
/// item does.
final class MeetingQuestionTests: XCTestCase {
    // MARK: - what each says

    func testACallThatBeganIsOfferedForFifteenSeconds() {
        let question = MeetingQuestion(.record("zoom"))

        XCTAssertEqual(question, .record(app: "zoom"))
        XCTAssertEqual(question.text, "zoom call — record it?")
        XCTAssertEqual(question.button, "record")
        XCTAssertEqual(question.buttonLabel, "record the zoom call")
        XCTAssertEqual(question.lasts, .seconds(15))
    }

    func testACallThatEndedAsksOnceForThirtySeconds() {
        let question = MeetingQuestion(.stop("zoom"))

        XCTAssertEqual(question, .stopAfterCall(app: "zoom"))
        XCTAssertEqual(question.text, "call ended — stop recording?")
        XCTAssertEqual(question.button, "stop")
        XCTAssertEqual(question.buttonLabel, "stop recording")
        XCTAssertEqual(question.lasts, .seconds(30))
    }

    func testTheNudgeAsksOnThePillForThirtySeconds() {
        let question = MeetingQuestion.stillRecording

        XCTAssertEqual(question.text, "still recording?")
        XCTAssertEqual(question.button, "stop")
        XCTAssertEqual(question.buttonLabel, "stop recording")
        XCTAssertEqual(question.lasts, .seconds(30))
    }

    // MARK: - what each answer does

    /// The recording is named after the call app, the way the file, its
    /// front matter and the hook will say it.
    func testRecordStartsAMeetingNamedAfterTheCall() {
        XCTAssertEqual(
            MeetingQuestion.record(app: "zoom").effect(of: .button),
            .startMeeting(name: "zoom")
        )
    }

    /// A click on the pill beside the button is a no for this call.
    func testAClickBesideRecordLeavesTheCallAlone() {
        XCTAssertEqual(
            MeetingQuestion.record(app: "zoom").effect(of: .elsewhere),
            .declineTheCall
        )
        XCTAssertEqual(
            MeetingQuestion.record(app: "zoom").effect(of: .unanswered),
            .nothing
        )
    }

    func testStopAfterTheCallStopsAndAnythingElseKeepsRecording() {
        let question = MeetingQuestion.stopAfterCall(app: "zoom")

        XCTAssertEqual(question.effect(of: .button), .stopMeeting)
        XCTAssertEqual(question.effect(of: .elsewhere), .nothing)
        XCTAssertEqual(question.effect(of: .unanswered), .nothing)
    }

    /// The nudge's two answers, on the pill: stop, or a click beside it,
    /// which is the notification's keep going. No answer is no answer: the
    /// notification still waits for one.
    func testTheNudgeStopsOrKeepsGoing() {
        let question = MeetingQuestion.stillRecording

        XCTAssertEqual(question.effect(of: .button), .stopMeeting)
        XCTAssertEqual(question.effect(of: .elsewhere), .keepGoing)
        XCTAssertEqual(question.effect(of: .unanswered), .nothing)
    }

    /// The app never starts or stops a recording by itself: only the button
    /// does either.
    func testNothingButTheButtonStartsOrStopsARecording() {
        let questions: [MeetingQuestion] = [
            .record(app: "zoom"), .stopAfterCall(app: "zoom"), .stillRecording,
        ]
        for question in questions {
            for answer in [MeetingQuestion.Answer.elsewhere, .unanswered] {
                let effect = question.effect(of: answer)
                XCTAssertNotEqual(effect, .stopMeeting, "\(question) \(answer)")
                if case .startMeeting = effect {
                    XCTFail("\(question) \(answer) starts a meeting")
                }
            }
        }
    }
}
