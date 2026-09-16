import AppKit
import Foundation

/// Quit, then come back on whatever is at our own path. On upgrade day that is
/// the version brew just put there: the bundle was replaced under a live
/// process, and restarting is the only way to run what was installed.
@MainActor
enum AppRelaunch {
    /// Not `open -n`: a second instance started while this one is still dying
    /// would be refused (`Capabilities.refusesASecondInstance`) and nothing
    /// would come back. So a shell waits for this process to be gone and then
    /// opens the app — handed off before we terminate, so it outlives us.
    static func now() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // fifteen seconds is the ceiling, not the plan: a process that will
        // not die must not leave a shell spinning forever.
        task.arguments = [
            "-c",
            """
            for _ in $(seq 60); do kill -0 \(pid) 2>/dev/null || break; \
            sleep 0.25; done; open "\(path)"
            """
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}
