import XCTest

/// The one thing the menu, the badge and the lamp read about a meeting,
/// worked out from what the coordinator already knows. One test per rule;
/// the inputs are plain values, so the order can be argued with here.
final class MeetingPhaseTests: XCTestCase {
    private func phase(
        _ state: MeetingSession.State,
        modelLoaded: Bool = true,
        problems: [MeetingSession.Problem] = [],
        writingOut: Bool = false,
        recovering: String? = nil
    ) -> MeetingPhase {
        MeetingPhase(
            state: state, modelLoaded: modelLoaded, problems: problems,
            writingOut: writingOut, recovering: recovering)
    }

    func testNoMeetingAndNothingBeingWrittenOutIsIdle() {
        XCTAssertEqual(phase(.idle), .idle)
        XCTAssertEqual(phase(.idle, modelLoaded: false), .idle)
    }

    /// The tap has not heard its start sound yet: nothing is trusted, so
    /// the meeting is getting ready whether the model is in or not.
    func testUntilTheTapIsHeardTheMeetingIsGettingReady() {
        XCTAssertEqual(phase(.provingItCanHear, modelLoaded: false), .gettingReady)
        XCTAssertEqual(phase(.provingItCanHear, modelLoaded: true), .gettingReady)
    }

    /// The tap was heard and the model is still loading: the audio is kept,
    /// and nothing is being read yet.
    func testUntilTheModelHasLoadedTheMeetingIsGettingReady() {
        XCTAssertEqual(phase(.recording, modelLoaded: false), .gettingReady)
    }

    func testOnceBothAreInTheMeetingIsRecording() {
        XCTAssertEqual(phase(.recording, modelLoaded: true), .recording)
    }

    /// A gap being rebuilt with no problem standing is still a meeting that
    /// records: the lamp says the gap, the menu keeps its clock.
    func testARebuildWithNoProblemReadsAsRecording() {
        XCTAssertEqual(phase(.rebuilding), .recording)
    }

    /// Several can stand; the phase carries the worst, which the session
    /// keeps first.
    func testAProblemStandingIsTheWorstOfThem() {
        XCTAssertEqual(
            phase(.recording, problems: [.cannotHearYourMic("MacBook Pro Microphone"), .diskNearlyFull]),
            .problem(.cannotHearYourMic("MacBook Pro Microphone")))
        XCTAssertEqual(
            phase(.rebuilding, problems: [.cannotHearTheCall]),
            .problem(.cannotHearTheCall))
    }

    /// A disk found nearly full at the start stands while the model is
    /// still loading: what is wrong is said over what is still to come.
    func testAProblemOutranksGettingReady() {
        XCTAssertEqual(
            phase(.recording, modelLoaded: false, problems: [.diskNearlyFull]),
            .problem(.diskNearlyFull))
    }

    func testAStoppedMeetingNotYetOnDiskIsBeingWrittenOut() {
        XCTAssertEqual(phase(.idle, writingOut: true), .writingOut(recovering: nil))
    }

    /// A spool a crash left, written out at launch, is writing out too, and
    /// says whose it is.
    func testARecoveryWhileItRunsIsBeingWrittenOut() {
        XCTAssertEqual(phase(.idle, recovering: "zoom"), .writingOut(recovering: "zoom"))
    }

    /// The meeting you just stopped is the one you are waiting on.
    func testYourStoppedMeetingOutranksARecovery() {
        XCTAssertEqual(
            phase(.idle, writingOut: true, recovering: "zoom"),
            .writingOut(recovering: nil))
    }

    /// The next meeting can record while the last is written out: the one
    /// recording is the one the menu, the badge and the lamp are about.
    func testAMeetingBeingRecordedOutranksOneBeingWrittenOut() {
        XCTAssertEqual(phase(.recording, writingOut: true, recovering: "zoom"), .recording)
        XCTAssertEqual(phase(.provingItCanHear, writingOut: true), .gettingReady)
        XCTAssertEqual(
            phase(.recording, problems: [.diskNearlyFull], writingOut: true),
            .problem(.diskNearlyFull))
    }

    /// The start sound never came back: the meeting is ending, not
    /// recording, and the pill says why.
    func testAMeetingThatCannotHearIsOver() {
        XCTAssertEqual(phase(.cannotHear, modelLoaded: false), .idle)
        XCTAssertEqual(phase(.cannotHear, writingOut: true), .writingOut(recovering: nil))
    }
}
