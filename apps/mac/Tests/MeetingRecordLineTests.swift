import XCTest

/// the meeting record's one line: what the unified log keeps and what "copy
/// diagnostics" hands over, so it is pinned word for word.
final class MeetingRecordLineTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    func testASavedMeetingIsOneLineOfEverythingItKnows() {
        let record = MeetingRecord(
            outcome: .saved,
            app: "zoom",
            model: "whisperLargeV3Turbo",
            startedAt: noonish,
            durationS: 3_728,
            gaps: 1,
            gapsLostS: 2_416,
            you: .init(turns: 2, words: 5),
            them: .init(turns: 2, words: 3),
            toDiskS: 4.2,
            recovered: true,
            events: [
                .init(.gapBegan, atS: 1_083),
                .init(.gapEnded, atS: 3_499),
            ],
            decoding: .init(
                decodedYou: 7, decodedThem: 12, failed: 1,
                mostBehindS: 9.5, lastBehindS: 2.5)
        )

        let expected: [String] = [
            "at=2026-10-02T12:22:31+05:30 outcome=saved",
            #"app="zoom" model=whisperLargeV3Turbo"#,
            "duration_s=3728 gaps=1 lost_s=2416",
            "you_turns=2 you_words=5 them_turns=2 them_words=3",
            "to_disk_s=4.2 recovered=1",
            "events=gap-began@1083,gap-ended@3499",
            "decoded_you=7 decoded_them=12 failed=1 most_behind_s=9.5 last_behind_s=2.5",
        ]
        XCTAssertEqual(record.line(in: kolkata), expected.joined(separator: " "))
    }

    /// nothing was captured, so the line is short — and a quote in an app's
    /// name stays inside it.
    func testAMeetingThatKeptNothingIsAShortLineThatSaysWhy() {
        let record = MeetingRecord(
            outcome: .nothingKept(.tapNeverHeard),
            app: #"jass's "call" app"#,
            model: "whisperLargeV3",
            startedAt: noonish,
            durationS: 3
        )

        let expected: [String] = [
            "at=2026-10-02T12:22:31+05:30 outcome=nothing-kept why=tap-never-heard",
            #"app="jass's \"call\" app" model=whisperLargeV3"#,
            "duration_s=3 gaps=0 lost_s=0",
            "you_turns=0 you_words=0 them_turns=0 them_words=0",
        ]
        XCTAssertEqual(record.line(in: kolkata), expected.joined(separator: " "))
    }

    /// the words a line says for each ending are what jass greps for.
    func testEveryEndingHasItsOwnWord() {
        let endings: [(MeetingRecord.Outcome, String)] = [
            (.saved, "outcome=saved"),
            (.nothingKept(.tapNeverHeard), "outcome=nothing-kept why=tap-never-heard"),
            (.nothingKept(.stoppedBeforeCapture), "outcome=nothing-kept why=stopped-before-capture"),
            (.modelFailed, "outcome=model-failed"),
            (.couldNotWrite, "outcome=couldnt-write"),
            (.couldNotRecover, "outcome=couldnt-recover"),
            (.setAside, "outcome=set-aside"),
            (.spoolUnreadable, "outcome=spool-unreadable"),
            (.nothingKept(.spoolEmpty), "outcome=nothing-kept why=spool-empty"),
            (.setAsideUnreadable, "outcome=set-aside-unreadable"),
            (.waitingForModel, "outcome=waiting-for-model"),
        ]

        for (outcome, words) in endings {
            let line = MeetingRecord(
                outcome: outcome, app: "zoom", model: "m", startedAt: noonish, durationS: 1
            ).line(in: kolkata)
            XCTAssertTrue(
                line.hasPrefix("at=2026-10-02T12:22:31+05:30 \(words) app="), line)
        }
    }
}
