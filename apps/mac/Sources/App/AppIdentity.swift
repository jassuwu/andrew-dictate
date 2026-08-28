import Foundation

/// Which build of the app this is, and where it is allowed to keep things.
///
/// A debug build and the released app used to be the same app as far as macOS
/// was concerned: same bundle identifier, same name, same Application Support
/// folder. That had two costs. TCC keys its grants to the bundle identifier and
/// the code signature, so the two builds fought over one permission record —
/// which is why testing a change meant installing a release on a second mac.
/// And both wrote to the same `dictionary.json` and `dictations.jsonl`, so a
/// development build could damage the archive its author actually uses.
///
/// A debug build now has its own identifier, its own name, and its own folder.
enum AppIdentity {
    /// The shipped identifier. Everything keys off equality with this rather
    /// than off a `.dev` suffix, so *anything* that is not exactly the release
    /// build gets development storage. A typo in a bundle identifier should
    /// send a build to its own folder, never to the real one.
    static let releaseBundleID = "gg.jass.dictate"
    static let releaseSupportDirectory = "Andrew Dictate"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? releaseBundleID
    }

    static var isReleaseBuild: Bool {
        bundleID == releaseBundleID
    }

    /// The folder under Application Support. The release name is pinned to the
    /// exact string it has always been — changing it would orphan every
    /// existing user's dictionary and archive.
    static var supportDirectoryName: String {
        supportDirectoryName(for: bundleID)
    }

    static func supportDirectoryName(for bundleID: String) -> String {
        bundleID == releaseBundleID
            ? releaseSupportDirectory
            : "\(releaseSupportDirectory) Dev"
    }

    /// Application Support, already namespaced. Every store should go through
    /// this rather than spelling the folder out again.
    static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// Logs are tagged with the real identifier, so a `log stream` filter can
    /// tell a development build from the shipped one.
    static var loggingSubsystem: String {
        bundleID
    }
}
