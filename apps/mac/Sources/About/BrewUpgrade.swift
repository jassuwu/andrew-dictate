import Foundation

/// The one-click update's command: `brew upgrade` for this cask, run the
/// way a terminal would run it, minus the terminal.
enum BrewUpgrade {
    /// the tap-qualified name is load-bearing beyond the copy: brew
    /// refreshes a third-party tap before `upgrade` when the name has a
    /// tap in it (every five minutes, not every day), so the release the
    /// site just announced is one brew can see.
    static let arguments = ["upgrade", "--cask", "jassuwu/tap/andrew-dictate"]

    /// generous: the dmg is a few hundred mb, and brew may update its taps
    /// first. a brew that is still going after this is stuck.
    static let timeout: TimeInterval = 10 * 60

    /// `environment` is this process's, which launchd gave a PATH with no
    /// brew on it. brew's own prefix goes first so whatever brew shells
    /// out to is brew's. no auto-update switch: the tap must refresh.
    static func command(
        brew: URL,
        environment: [String: String]
    ) -> Command {
        let prefix = brew
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var environment = environment
        environment["PATH"] = [
            prefix.appending(path: "bin").path(percentEncoded: false),
            prefix.appending(path: "sbin").path(percentEncoded: false),
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["NONINTERACTIVE"] = "1"
        return Command(
            executable: brew,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }
}
