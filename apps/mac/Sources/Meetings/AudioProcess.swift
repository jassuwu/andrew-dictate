import Foundation

/// One process Core Audio has open for audio, as the HAL describes it: who it
/// is, and whether its input or its output is running right now.
struct AudioProcess: Equatable, Sendable {
    let pid: Int32
    /// Missing for some daemons and helpers, which then belong to no app.
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

extension MeetingApps {
    /// What the call apps are doing, as the call watcher wants it: one entry
    /// per app however many processes it plays and listens through, and none
    /// for an app doing neither. Our own process is left out by pid, so
    /// dictation and a meeting's own capture never look like a call; so is
    /// every process that is not a call app's.
    ///
    /// In the order each app first appears, which means nothing: the watcher
    /// does not read anything into it.
    static func apps(in processes: [AudioProcess], leavingOut ownPID: Int32) -> [CallWatcher.App] {
        var order: [String] = []
        var mic: Set<String> = []
        var audio: Set<String> = []
        for process in processes where process.pid != ownPID {
            guard let bundleID = process.bundleID,
                  let app = callApp(bundleID: bundleID)?.name,
                  process.isRunningInput || process.isRunningOutput
            else { continue }
            if !order.contains(app) { order.append(app) }
            if process.isRunningInput { mic.insert(app) }
            if process.isRunningOutput { audio.insert(app) }
        }
        return order.map { app in
            CallWatcher.App(name: app, holdsMic: mic.contains(app), playsAudio: audio.contains(app))
        }
    }
}
