import XCTest

/// A meeting transcribed again leaves a record of its own, marked as one:
/// in its line, on disk, and — for the records written before the mark
/// existed — not there at all.
final class MeetingRecordAgainTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    private func again() -> MeetingRecord {
        MeetingRecord(
            outcome: .saved, app: "zoom", model: "whisperLargeV3", startedAt: noonish,
            durationS: 3_600, you: .init(turns: 2, words: 9), them: .init(turns: 3, words: 41),
            toDiskS: 83,
            coverage: .init(result: .pass, farSideLoudS: 3_000),
            audioKept: true, audioKeptUntil: noonish.addingTimeInterval(86_400),
            again: true)
    }

    func testARecordOfATranscriptMadeAgainSaysSoInItsLine() {
        XCTAssertTrue(again().line(in: kolkata).contains(" again=1 "), again().line(in: kolkata))
        XCTAssertTrue(again().line(in: kolkata).contains(" to_disk_s=83 "))
    }

    /// the flag is only there when true, like the others: a meeting that
    /// ended reads the way it always did.
    func testARecordOfAMeetingThatEndedHasNoSuchField() {
        var first = again()
        first.again = false

        XCTAssertFalse(first.line(in: kolkata).contains("again"), first.line(in: kolkata))
    }

    func testTheMarkGoesToDiskAndBack() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(MeetingRecord.self, from: encoder.encode(again()))

        XCTAssertEqual(back, again())
        XCTAssertTrue(back.again)
    }

    /// a record from before the mark was not of a rerun.
    func testARecordFromBeforeTheMarkStillReads() throws {
        let older = #"{"app":"zoom","durationS":60,"model":"m","outcome":"saved","startedAt":"2026-10-02T06:52:31Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(MeetingRecord.self, from: Data(older.utf8))

        XCTAssertFalse(record.again)
    }
}
