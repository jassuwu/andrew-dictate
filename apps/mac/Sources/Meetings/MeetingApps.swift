import Foundation

/// The apps a call happens in (ADR 0047): zoom, slack, teams, facetime, and
/// the browsers meet runs in. Nothing here decides what a meeting hears — the
/// tap is the whole mac (ADR 0049), so no app is ever picked or followed.
/// This is how a process is recognised as a call app, and the word a
/// sentence uses for it.
enum MeetingApps {
    struct CallApp: Equatable, Sendable {
        let bundleID: String
        /// Short and lowercase, the way a line on screen says it: "zoom".
        let name: String
    }

    static let callApps: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "zoom"),
        CallApp(bundleID: "com.microsoft.teams2", name: "teams"),
        CallApp(bundleID: "com.microsoft.teams", name: "teams"),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "slack"),
        CallApp(bundleID: "com.apple.FaceTime", name: "facetime"),
        CallApp(bundleID: "com.google.Chrome", name: "chrome"),
        CallApp(bundleID: "com.apple.Safari", name: "safari"),
        CallApp(bundleID: "company.thebrowser.Browser", name: "arc"),
        CallApp(bundleID: "org.mozilla.firefox", name: "firefox"),
        CallApp(bundleID: "com.brave.Browser", name: "brave"),
        CallApp(bundleID: "com.microsoft.edgemac", name: "edge"),
    ]

    /// The call app with this bundle id, or nil when it is not one.
    static func callApp(bundleID: String) -> CallApp? {
        callApps.first { $0.bundleID == bundleID }
    }
}
