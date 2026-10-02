import XCTest

/// The coverage check in the meeting record: in its line, on disk, and in a
/// record written before it was there.
final class CoverageRecordTests: XCTestCase {
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-10-02 12:22:31 in kolkata.
    private let noonish = Date(timeIntervalSince1970: 1_790_923_951)

    /// a thin save's line ends with what the check found and what was kept,
    /// so a grep for `coverage=thin` finds every one.
    func testAThinSaveIsOneLineWithTheCheckAndTheAudioOnTheEnd() {
        let record = MeetingRecord(
            outcome: .savedThin,
            app: "zoom",
            model: "parakeetV3",
            startedAt: noonish,
            durationS: 3_600,
            them: .init(turns: 1, words: 3),
            coverage: .init(
                result: .thin, reason: "far fewer words than the talk that was heard",
                speechYouS: 0, speechThemS: 3_600, unreadYouS: 0, unreadThemS: 12.5,
                bleed: 4, farSideLoudS: 3_412.3),
            audioKept: true
        )

        let expected: [String] = [
            "at=2026-10-02T12:22:31+05:30 outcome=saved-thin",
            #"app="zoom" model=parakeetV3"#,
            "duration_s=3600 gaps=0 lost_s=0",
            "you_turns=0 you_words=0 them_turns=1 them_words=3",
            #"coverage=thin coverage_why="far fewer words than the talk that was heard""#,
            "speech_you_s=0 speech_them_s=3600 unread_you_s=0 unread_them_s=12.5 bleed=4",
            "far_loud_s=3412.3",
            "audio=kept",
        ]
        XCTAssertEqual(record.line(in: kolkata), expected.joined(separator: " "))
    }

    /// an engine that keeps no count has no speech to say, and audio kept
    /// until a date says the date.
    func testAPassWithNoCountAndAudioKeptForADaySaysOnlyWhatItKnows() {
        let record = MeetingRecord(
            outcome: .saved,
            app: "meeting",
            model: "whisperLargeV3",
            startedAt: noonish,
            durationS: 60,
            coverage: .init(result: .pass, farSideLoudS: 41),
            audioKept: true,
            audioKeptUntil: noonish.addingTimeInterval(86_400)
        )

        XCTAssertTrue(record.line(in: kolkata).hasSuffix(
            "coverage=pass far_loud_s=41 audio=kept audio_until=2026-10-03T12:22:31+05:30"),
            record.line(in: kolkata))
    }

    func testAPassAfterARerunSaysWhyItWasReadAgain() {
        let record = MeetingRecord(
            outcome: .saved, app: "meeting", model: "parakeetV3", startedAt: noonish,
            durationS: 60,
            coverage: .init(
                result: .passAfterRerun, reason: "some of what was said could not be read",
                farSideLoudS: 50))

        XCTAssertTrue(record.line(in: kolkata).hasSuffix(
            #"coverage=pass-after-rerun coverage_why="some of what was said could not be read" far_loud_s=50"#),
            record.line(in: kolkata))
    }

    /// the record goes to disk and comes back the same.
    func testTheCoverageAndTheKeptAudioGoToDiskAndBack() throws {
        let record = MeetingRecord(
            outcome: .savedThin, app: "zoom", model: "parakeetV3", startedAt: noonish,
            durationS: 3_600,
            coverage: .init(
                result: .thin, reason: "some of what was said could not be read",
                speechYouS: 10, speechThemS: 20, unreadYouS: 5, unreadThemS: 0,
                bleed: 1, farSideLoudS: 30),
            audioKept: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))

        XCTAssertEqual(back, record)
    }

    /// a record from before the check has no coverage and kept no audio.
    func testARecordFromBeforeTheCheckStillReads() throws {
        let older = #"{"app":"zoom","durationS":60,"model":"m","outcome":"saved","startedAt":"2026-10-02T06:52:31Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(MeetingRecord.self, from: Data(older.utf8))

        XCTAssertNil(record.coverage)
        XCTAssertFalse(record.audioKept)
        XCTAssertNil(record.audioKeptUntil)
    }
}
