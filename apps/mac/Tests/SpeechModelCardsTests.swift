import XCTest

/// every model can do either job, so each job's cards show all of them,
/// each with what it costs in that job.
final class SpeechModelCardsTests: XCTestCase {
    func testEveryModelIsOnBothJobsCards() {
        XCTAssertEqual(Set(SpeechModel.cards(for: .dictation)), Set(SpeechModel.allCases))
        XCTAssertEqual(Set(SpeechModel.cards(for: .meetings)), Set(SpeechModel.allCases))
    }

    /// the job's own default leads its cards.
    func testEachJobLeadsWithItsDefault() {
        XCTAssertEqual(SpeechModel.cards(for: .dictation).first, SpeechModel.dictationDefault)
        XCTAssertEqual(SpeechModel.cards(for: .meetings).first, SpeechModel.meetingDefault)
    }

    func testOnlyWhistleSaysItIsExperimental() {
        XCTAssertEqual(SpeechModel.whistle.badge, "experimental")
        XCTAssertEqual(SpeechModel.allCases.filter { $0.badge != nil }, [.whistle])
    }

    /// a card states the consequence for its own job: whisper is slow for
    /// dictation, parakeet garbles a language it doesn't know in a meeting.
    func testATraitIsWrittenForTheJobItIsShownIn() {
        for model in SpeechModel.allCases {
            XCTAssertFalse(model.trait(for: .dictation).isEmpty, "\(model)")
            XCTAssertFalse(model.trait(for: .meetings).isEmpty, "\(model)")
        }
        XCTAssertTrue(SpeechModel.whisperLargeV3.trait(for: .dictation).contains("slow"))
        XCTAssertTrue(SpeechModel.parakeetV2.trait(for: .meetings).contains("english only"))
    }

    /// a meeting recorded with whistle names it in its manifest, and a
    /// build reading that manifest gets whistle back.
    func testWhistleIsStoredByItsName() throws {
        let stored = try JSONEncoder().encode(SpeechModel.whistle)
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), #""whistle""#)
        XCTAssertEqual(SpeechModel(storedDictationValue: "whistle"), .whistle)
    }

    func testRecordWithListsWhistleWhenItIsOnThisMac() {
        let choices = RecordWith.choices(
            installed: [.whisperLargeV3, .whistle],
            default: .whisperLargeV3,
            isRecording: false)

        XCTAssertEqual(choices, [RecordWith.Choice(model: .whistle, title: "whistle")])
    }
}
