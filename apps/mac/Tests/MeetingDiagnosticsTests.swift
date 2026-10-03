import XCTest

/// "copy diagnostics" with meetings in it: the presses as they were, then
/// the last meetings as their own log wrote them, so a friend with a lost
/// meeting pastes one message and not two.
final class MeetingDiagnosticsTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    /// the presses, then the meetings, newest last in each.
    func testDiagnosticsAreTheSetupThenThePressesThenTheLastMeetings() {
        let text = PressDiagnostics.text(
            setup: setup,
            presses: [refused(endingAt: 0)],
            meetings: [
                meeting(lasting: 60),
                meeting(lasting: 3_728, outcome: .nothingKept(.tapNeverHeard)),
            ],
            timeZone: kolkata
        )

        XCTAssertEqual(
            text,
            [
                "Andrew Dictate 0.9.4 (6)",
                "macOS 27.0.1",
                "speech model v2",
                "default mic: MacBook Pro Microphone (built-in)",
                "last press:",
                "at=2026-10-02T12:22:31+05:30 outcome=refused why=model-not-ready end_ms=0 model=v2",
                "last 2 meetings, newest last:",
                #"at=2026-10-02T12:22:31+05:30 outcome=saved app="zoom" model=whisperLargeV3Turbo duration_s=60 gaps=0 lost_s=0 you_turns=0 you_words=0 them_turns=0 them_words=0"#,
                #"at=2026-10-02T12:22:31+05:30 outcome=nothing-kept why=tap-never-heard app="zoom" model=whisperLargeV3Turbo duration_s=3728 gaps=0 lost_s=0 you_turns=0 you_words=0 them_turns=0 them_words=0"#,
            ].joined(separator: "\n")
        )
    }

    /// twenty is enough to see what a week of meetings did and short enough
    /// to paste anywhere.
    func testDiagnosticsCarryOnlyTheNewestTwenty() {
        let meetings = (0..<25).map { meeting(lasting: Double($0)) }

        let lines = PressDiagnostics.text(
            setup: setup,
            presses: [],
            meetings: meetings,
            timeZone: kolkata
        ).split(separator: "\n")

        XCTAssertEqual(lines.count, 5 + 1 + 20)
        guard lines.count == 5 + 1 + 20 else { return }
        XCTAssertEqual(lines[5], "last 20 meetings, newest last:")
        XCTAssertTrue(lines[6].contains(" duration_s=5 "), "\(lines[6])")
        XCTAssertTrue(lines.last!.contains(" duration_s=24 "), "\(lines.last!)")
    }

    func testOneMeetingIsNotCalledMeetings() {
        let text = PressDiagnostics.text(
            setup: setup,
            presses: [],
            meetings: [meeting(lasting: 60)],
            timeZone: kolkata
        )

        XCTAssertTrue(text.contains("\nlast meeting:\n"), text)
    }

    /// a mac that never recorded a meeting is not asked about them: the text
    /// is what it was.
    func testNoMeetingsAddsNothing() {
        let without = PressDiagnostics.text(
            setup: setup, presses: [], timeZone: kolkata)
        let with = PressDiagnostics.text(
            setup: setup, presses: [], meetings: [], timeZone: kolkata)

        XCTAssertEqual(with, without)
        XCTAssertFalse(with.contains("meeting"), with)
    }

    /// records that will not read are not an empty file.
    func testUnreadableMeetingRecordsDoNotPassForNone() {
        let text = PressDiagnostics.text(
            setup: setup, presses: [], meetings: nil, timeZone: kolkata)

        XCTAssertTrue(text.hasSuffix("\ncouldn't read the meeting records"), text)
    }

    /// one log that will not read must not take the other with it.
    func testAPressLogThatWillNotReadStillShowsTheMeetings() {
        let text = PressDiagnostics.text(
            setup: setup,
            presses: nil,
            meetings: [meeting(lasting: 60)],
            timeZone: kolkata
        )

        XCTAssertTrue(
            text.contains("\ncouldn't read the press log\nlast meeting:\n"), text)
    }

    // MARK: - helpers

    private var setup: PressDiagnostics.Setup {
        PressDiagnostics.Setup(
            appVersion: "0.9.4",
            build: "6",
            macOS: "27.0.1",
            engine: "v2",
            defaultMic: MicDescription(name: "MacBook Pro Microphone", transport: .builtIn)
        )
    }

    private func refused(endingAt end: Int) -> PressRecord {
        PressRecord(
            outcome: .refused(.modelNotReady),
            startedAt: noonish,
            mic: nil,
            samples: nil,
            peak: nil,
            words: nil,
            stages: PressRecord.Stages(ended: end),
            engine: "v2",
            capped: false,
            retry: false,
            mainStallMs: nil
        )
    }

    private func meeting(
        lasting seconds: Double,
        outcome: MeetingRecord.Outcome = .saved
    ) -> MeetingRecord {
        MeetingRecord(
            outcome: outcome,
            app: "zoom",
            model: "whisperLargeV3Turbo",
            startedAt: noonish,
            durationS: seconds
        )
    }
}
