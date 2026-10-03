import XCTest

/// what the speaker split did at the stop, in the meeting's record: how long
/// its last pieces took after the stop, and how many pieces it let go.
final class MeetingRecordSplitTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    /// beside the seconds to the file, the split's part of them, and the
    /// pieces whose speakers are not in it.
    func testTheSplitsTailAndWhatItLetGoAreOnTheLineAfterTheSecondsToTheFile() {
        var record = MeetingRecord(
            outcome: .saved, app: "meeting", model: "whisperLargeV3",
            startedAt: noonish, durationS: 3_600, toDiskS: 6.4)
        record.split = .init(tailS: 1.3, skipped: 1)

        XCTAssertEqual(record.line(in: kolkata), [
            "at=2026-10-02T12:22:31+05:30 outcome=saved",
            #"app="meeting" model=whisperLargeV3"#,
            "duration_s=3600 gaps=0 lost_s=0",
            "you_turns=0 you_words=0 them_turns=0 them_words=0",
            "to_disk_s=6.4 split_tail_s=1.3 split_skipped=1",
        ].joined(separator: " "))
    }

    /// a meeting with no split — its models were not on the mac — says
    /// nothing about one.
    func testNoSplitIsNotOnTheLine() {
        let record = MeetingRecord(
            outcome: .saved, app: "meeting", model: "whisperLargeV3",
            startedAt: noonish, durationS: 60, toDiskS: 2)

        XCTAssertFalse(record.line(in: kolkata).contains("split_"))
    }

    /// kept and read back; and a record from before there was a split to
    /// tell of reads as one with none.
    func testTheSplitIsKeptAndAnOlderRecordHasNone() throws {
        var record = MeetingRecord(
            outcome: .saved, app: "meeting", model: "whisperLargeV3",
            startedAt: noonish, durationS: 60)
        record.split = .init(tailS: 0.4, skipped: 0)

        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)

        let older = #"{"outcome":"saved","app":"meeting","model":"whisperLargeV3","startedAt":0,"durationS":60}"#
        XCTAssertNil(try JSONDecoder().decode(MeetingRecord.self, from: Data(older.utf8)).split)
    }

    /// from a meeting's own report: seconds to a tenth.
    func testTheRecordOfAMeetingTakesTheSplitsReport() {
        let record = MeetingRecord(
            .saved, app: "meeting", model: .whisperLargeV3, startedAt: noonish,
            duration: .seconds(600),
            split: SpeakerSplit.Report(tail: .milliseconds(1_260), skipped: 2))

        XCTAssertEqual(record.split, .init(tailS: 1.3, skipped: 2))
    }
}
