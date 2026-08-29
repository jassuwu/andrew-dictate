import AppKit

struct RunningApp: Identifiable, Equatable, Sendable {
    var id: pid_t { pid }

    let name: String
    let bundleID: String?
    let pid: pid_t
}

/// Which running apps the menu offers to record. Meeting apps first, in a
/// fixed order, because "record a meeting ▸ zoom" is the whole gesture; the
/// rest follow alphabetically so a call in some app we have never heard of is
/// still one click away.
enum MeetingApps {
    /// Bundle ids in menu order. Browsers are here because meet lives in one.
    static let known: [String] = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    private static let shortNames: [String: String] = [
        "us.zoom.xos": "zoom",
        "com.microsoft.teams2": "teams",
        "com.microsoft.teams": "teams",
        "com.tinyspeck.slackmacgap": "slack",
        "com.apple.FaceTime": "facetime",
        "com.hnc.Discord": "discord",
        "com.google.Chrome": "chrome",
        "com.apple.Safari": "safari",
        "company.thebrowser.Browser": "arc",
        "org.mozilla.firefox": "firefox",
        "com.brave.Browser": "brave",
        "com.microsoft.edgemac": "edge",
    ]

    /// Which bundle ids the tap should follow for an app. The spike found
    /// that the main app is often not the process that plays the audio:
    /// every Chromium browser hands sound to a `…helper` utility process,
    /// and Safari's audio comes out of a shared WebKit XPC service that has
    /// no `com.apple.Safari` in it at all. Listing the helpers too costs
    /// nothing when they do not exist and is the whole feature when they do.
    static func tapBundleIDs(for app: RunningApp) -> [String] {
        guard let id = app.bundleID else { return [] }
        switch id {
        case "com.apple.Safari":
            return [id, "com.apple.WebKit.GPU"]
        case "company.thebrowser.Browser":
            return [id, "company.thebrowser.browser.helper"]
        default:
            return [id, id + ".helper", id + ".Helper"]
        }
    }

    static func displayName(_ app: RunningApp) -> String {
        if let id = app.bundleID, let short = shortNames[id] {
            return short
        }
        return app.name.lowercased()
    }

    static func rank(_ apps: [RunningApp]) -> (meeting: [RunningApp], other: [RunningApp]) {
        let meeting = known.compactMap { id in
            apps.first { $0.bundleID == id }
        }
        let other = apps
            .filter { app in !meeting.contains(app) }
            .sorted {
                displayName($0).localizedCaseInsensitiveCompare(displayName($1))
                    == .orderedAscending
            }
        return (meeting, other)
    }

    @MainActor
    static func running(
        workspace: NSWorkspace = .shared,
        excludingBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [RunningApp] {
        var seen = Set<pid_t>()
        return workspace.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != excludingBundleID,
                  seen.insert(app.processIdentifier).inserted
            else {
                return nil
            }
            return RunningApp(
                name: app.localizedName
                    ?? app.bundleIdentifier
                    ?? "app \(app.processIdentifier)",
                bundleID: app.bundleIdentifier,
                pid: app.processIdentifier
            )
        }
    }
}
