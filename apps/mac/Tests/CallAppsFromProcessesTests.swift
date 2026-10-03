import XCTest

/// What Core Audio says about its processes, turned into what the call
/// watcher wants: one entry per call app, holding the mic, playing audio, or
/// both, and nothing for anyone else.
final class CallAppsFromProcessesTests: XCTestCase {
    private let ours: Int32 = 500

    private func process(
        _ bundleID: String?,
        pid: Int32 = 900,
        input: Bool = false,
        output: Bool = false
    ) -> AudioProcess {
        AudioProcess(
            pid: pid, bundleID: bundleID,
            isRunningInput: input, isRunningOutput: output)
    }

    private func apps(_ processes: [AudioProcess]) -> [CallWatcher.App] {
        MeetingApps.apps(in: processes, leavingOut: ours)
    }

    /// Chrome plays and listens through its helpers. However many of them
    /// there are, it is one app.
    func testHelpersMergeIntoTheirApp() {
        XCTAssertEqual(
            apps([
                process("com.google.Chrome", pid: 900, output: true),
                process("com.google.Chrome.helper", pid: 901, input: true, output: true),
                process("com.google.Chrome.helper.Renderer", pid: 902, output: true),
            ]),
            [CallWatcher.App(name: "chrome", holdsMic: true, playsAudio: true)]
        )
    }

    /// Dictation and a meeting's own capture hold the mic, and the start
    /// sound plays through us. None of it is a call, whatever the process
    /// calls itself.
    func testOurOwnProcessIsLeftOut() {
        XCTAssertEqual(
            apps([
                process("us.zoom.xos", pid: ours, input: true, output: true),
                process(nil, pid: ours, input: true, output: true),
            ]),
            []
        )
    }

    func testAnAppThatIsNotACallAppIsIgnored() {
        XCTAssertEqual(
            apps([
                process("com.apple.VoiceMemos", input: true, output: true),
                process("com.spotify.client", output: true),
                process(nil, pid: 77, input: true, output: true),
            ]),
            []
        )
    }

    /// Zoom listens in one process and plays in another: still one app, and
    /// it holds the mic and plays audio both.
    func testInputOnOneProcessAndOutputOnAnotherIsOneAppDoingBoth() {
        XCTAssertEqual(
            apps([
                process("us.zoom.xos", pid: 900, input: true),
                process("us.zoom.xos.ZoomAudioHelper", pid: 901, output: true),
            ]),
            [CallWatcher.App(name: "zoom", holdsMic: true, playsAudio: true)]
        )
    }

    /// The old teams and the new one are both teams.
    func testTwoBundlesOfTheSameAppAreOneApp() {
        XCTAssertEqual(
            apps([
                process("com.microsoft.teams", pid: 900, output: true),
                process("com.microsoft.teams2", pid: 901, input: true),
            ]),
            [CallWatcher.App(name: "teams", holdsMic: true, playsAudio: true)]
        )
    }

    /// Core Audio lists every process that has opened audio, running or
    /// not. One that has opened it and is doing neither is not there.
    func testAnAppWithNothingRunningIsLeftOut() {
        XCTAssertEqual(
            apps([
                process("com.tinyspeck.slackmacgap", pid: 900),
                process("com.google.Chrome.helper", pid: 901, output: true),
            ]),
            [CallWatcher.App(name: "chrome", holdsMic: false, playsAudio: true)]
        )
    }

    /// Two call apps at once stay two apps; the watcher picks between them.
    func testEachCallAppIsItsOwnEntry() {
        XCTAssertEqual(
            apps([
                process("us.zoom.xos", pid: 900, input: true, output: true),
                process("com.google.Chrome.helper", pid: 901, output: true),
            ]),
            [
                CallWatcher.App(name: "zoom", holdsMic: true, playsAudio: true),
                CallWatcher.App(name: "chrome", holdsMic: false, playsAudio: true),
            ]
        )
    }
}
