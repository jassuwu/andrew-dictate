import XCTest

/// How long a meeting's audio waits after its transcript is written: one
/// setting, beside the other meeting settings, stored the way they are.
@MainActor
final class KeepMeetingAudioSettingTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        suiteName = "AndrewDictateTests.KeepMeetingAudio.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func testMeetingAudioIsKeptForADayUntilSomeoneSaysOtherwise() {
        let settings = AppSettings(userDefaults: userDefaults)

        XCTAssertEqual(settings.keepMeetingAudio, .oneDay)
    }

    func testTheChoiceSurvivesARelaunch() {
        let settings = AppSettings(userDefaults: userDefaults)
        settings.keepMeetingAudio = .deleteAtOnce

        XCTAssertEqual(AppSettings(userDefaults: userDefaults).keepMeetingAudio, .deleteAtOnce)

        settings.keepMeetingAudio = .sevenDays

        XCTAssertEqual(AppSettings(userDefaults: userDefaults).keepMeetingAudio, .sevenDays)
    }

    /// a value a later build wrote, and this one has no name for, is the
    /// default: never a meeting kept longer than anyone chose.
    func testAChoiceThisBuildDoesNotKnowIsADay() {
        userDefaults.set("forever", forKey: "AndrewDictate.keepMeetingAudio")

        XCTAssertEqual(AppSettings(userDefaults: userDefaults).keepMeetingAudio, .oneDay)
    }

    /// the three choices, in the order the row offers them, in its words.
    func testTheChoicesAreSaidPlainly() {
        XCTAssertEqual(
            KeepMeetingAudio.allCases.map(\.label),
            ["delete at once", "one day", "seven days"])
    }

    /// the row's caption says what the choice does: `delete at once` keeps
    /// nothing for a while to delete later, and a thin transcript keeps its
    /// audio whichever is chosen.
    func testTheCaptionFitsTheChoice() {
        XCTAssertEqual(
            KeepMeetingAudio.deleteAtOnce.caption,
            "deleted the moment the transcript is written. a transcript that comes out thin keeps its audio on this mac, never in the transcripts folder, until you delete it.")
        for kept in [KeepMeetingAudio.oneDay, .sevenDays] {
            XCTAssertEqual(
                kept.caption,
                "it stays on this mac, never in the transcripts folder, and is deleted by itself after that. a transcript that comes out thin keeps its audio until you delete it.")
        }
    }
}
