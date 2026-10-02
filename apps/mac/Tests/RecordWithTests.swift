import XCTest

/// What `record with ▸` lists under `record a meeting`: the meeting models
/// on this mac that are not the one settings picked.
final class RecordWithTests: XCTestCase {
    func testTwoModelsOnThisMacListTheOneThatIsNotTheDefault() {
        let choices = RecordWith.choices(
            installed: [.whisperLargeV3, .whisperLargeV3Turbo],
            default: .whisperLargeV3,
            isRecording: false)

        XCTAssertEqual(choices, [
            RecordWith.Choice(
                model: .whisperLargeV3Turbo,
                title: "whisper turbo — every language, as spoken · faster"),
        ])
    }
}
