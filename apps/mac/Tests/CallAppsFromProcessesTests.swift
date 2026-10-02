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
}
