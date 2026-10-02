import XCTest

final class CallWatcherTests: XCTestCase {
    private func watcher() -> CallWatcher {
        CallWatcher(startAfter: .seconds(3), endAfter: .seconds(30))
    }

    private func app(
        _ name: String,
        mic: Bool = true,
        audio: Bool = true
    ) -> CallWatcher.App {
        CallWatcher.App(name: name, holdsMic: mic, playsAudio: audio)
    }

    // MARK: - a call begins

    func testAMicAndAudioHeldForTheStartThresholdAreACall() {
        var watcher = watcher()
        let zoom = app("zoom")

        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([zoom], isRecording: false, at: .seconds(2)), [])
        XCTAssertEqual(
            watcher.observe([zoom], isRecording: false, at: .seconds(3)),
            [.record("zoom")]
        )
    }
}
