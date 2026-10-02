import Foundation

/// The update line: whether the menu says `update to <x>`, and what clicking
/// it does. Pure — the watcher asks the network and the clock, this decides.
enum UpdateOffer {
    enum Install: Equatable, Sendable {
        case homebrew
        case dmg
    }

    struct Line: Equatable, Sendable {
        /// `0.9.10`, never `v0.9.10`: the menu reads like a sentence.
        let version: String

        var title: String {
            "update to \(version)"
        }
    }

    /// `latest` is what dictate.jass.gg answered; nil, or anything that is
    /// not a version, is no line. `onDisk` is the bundle in /Applications,
    /// which brew may already have replaced under this process — the newer
    /// of the two is what the user has.
    static func line(
        latest: String?,
        running: String,
        onDisk: String? = nil,
        install: Install
    ) -> Line? {
        guard let latest else {
            return nil
        }
        var have = running
        if let onDisk, UpdateCheck.isNewer(tag: onDisk, than: running) {
            have = onDisk
        }
        guard UpdateCheck.isNewer(tag: latest, than: have) else {
            return nil
        }
        let version = UpdateCheck.numbers(in: latest)
            .map(String.init)
            .joined(separator: ".")
        return Line(version: version)
    }
}
