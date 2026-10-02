import Foundation

/// The update line: whether the menu says `update to <x>`, and what clicking
/// it does. Pure — the watcher asks the network and the clock, this decides.
enum UpdateOffer {
    enum Install: Equatable, Sendable {
        case homebrew
        case dmg

        static let caskroom = URL(
            fileURLWithPath: "/opt/homebrew/Caskroom/andrew-dictate",
            isDirectory: true
        )

        /// brew put it there, brew replaces it. apple silicon only, so
        /// /opt/homebrew is the only caskroom there is.
        static func detect(
            caskroom: URL = Install.caskroom,
            fileManager: FileManager = .default
        ) -> Install {
            fileManager.fileExists(atPath: caskroom.path(percentEncoded: false))
                ? .homebrew
                : .dmg
        }
    }

    /// what the click is for, not how it is done: `UpdateHandOff` decides
    /// that. today a brew upgrade is copied for the user to paste; running
    /// it in one click replaces the hand-off, not this.
    enum Action: Equatable, Sendable {
        case brewUpgrade(String)
        case openReleasePage(URL)
    }

    static let releasesPage = URL(
        string: "https://github.com/jassuwu/andrew-dictate/releases/latest"
    )!

    struct Line: Equatable, Sendable {
        /// `0.9.10`, never `v0.9.10`: the menu reads like a sentence.
        let version: String
        let action: Action

        var title: String {
            "update to \(version)"
        }
    }

    /// a dmg user handed a `brew upgrade` line would paste an error into
    /// their terminal, so they get the page the dmg is on instead.
    static func action(for install: Install) -> Action {
        switch install {
        case .homebrew:
            .brewUpgrade(UpdateCheck.upgradeCommand)
        case .dmg:
            .openReleasePage(releasesPage)
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
        return Line(version: version, action: action(for: install))
    }
}
