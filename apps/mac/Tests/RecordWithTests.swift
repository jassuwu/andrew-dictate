import XCTest

/// What `record with ▸` lists under `record a meeting`: the meeting models
/// on this mac that are not the one settings picked.
final class RecordWithTests: XCTestCase {
    func testOneModelOnThisMacHasNothingToChooseFrom() {
        let choices = RecordWith.choices(
            installed: [.whisperLargeV3],
            default: .whisperLargeV3,
            isRecording: false)

        XCTAssertEqual(choices, [])
    }

    /// the default is not here but another model is: `record a meeting`
    /// sends you to setup, and this is the one way to record right away.
    func testAModelThatIsNotTheDefaultIsListedEvenWhenTheDefaultIsMissing() {
        let choices = RecordWith.choices(
            installed: [.parakeetV3],
            default: .whisperLargeV3,
            isRecording: false)

        XCTAssertEqual(choices.map(\.model), [.parakeetV3])
        XCTAssertEqual(choices.first?.title, "parakeet")
    }

    func testTwoModelsOnThisMacListTheOneThatIsNotTheDefault() {
        let choices = RecordWith.choices(
            installed: [.whisperLargeV3, .whisperLargeV3Turbo],
            default: .whisperLargeV3,
            isRecording: false)

        XCTAssertEqual(choices, [
            RecordWith.Choice(model: .whisperLargeV3Turbo, title: "whisper turbo"),
        ])
    }

    /// the order is the cards' own, however the set happens to be held, so
    /// the menu does not shuffle between launches. a set's order changes
    /// from one launch to the next, so a menu that leans on it fails this
    /// one only some of the time.
    func testThreeModelsListTheTwoOthersInTheOrderOfTheCards() {
        let choices = RecordWith.choices(
            installed: [.parakeetV3, .whisperLargeV3Turbo, .whisperLargeV3],
            default: .whisperLargeV3Turbo,
            isRecording: false)

        XCTAssertEqual(choices.map(\.model), [.whisperLargeV3, .parakeetV3])
    }

    /// `record a meeting` is not in the menu while one runs, so neither is
    /// the line under it.
    func testNothingIsListedWhileAMeetingIsRecording() {
        let choices = RecordWith.choices(
            installed: [.whisperLargeV3, .whisperLargeV3Turbo, .parakeetV3],
            default: .whisperLargeV3,
            isRecording: true)

        XCTAssertEqual(choices, [])
    }
}
