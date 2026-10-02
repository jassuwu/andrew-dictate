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

    /// A browser tab playing music is not a call, and neither is a podcast.
    func testAudioAloneIsNotACall() {
        var watcher = watcher()
        let music = app("chrome", mic: false, audio: true)

        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(60)), [])
        XCTAssertEqual(watcher.observe([music], isRecording: false, at: .seconds(600)), [])
    }

    /// Dictation, a screen recorder and a voice memo all hold the mic without
    /// anyone being on a call.
    func testTheMicAloneIsNotACall() {
        var watcher = watcher()
        let listening = app("chrome", mic: true, audio: false)

        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(0)), [])
        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(60)), [])
        XCTAssertEqual(watcher.observe([listening], isRecording: false, at: .seconds(600)), [])
    }
}
