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

    /// the site's answer, never github's: the automatic check has no
    /// fallback (apps/site/api/latest.ts).
    static let endpoint = URL(string: "https://dictate.jass.gg/api/latest")!

    /// what the site said. `unreachable` — offline, a timeout, dns — is
    /// not an answer, so it is not today's check either: the next tick
    /// tries again, which matters on wake, when the timer beats the wi-fi.
    enum Answer: Equatable, Sendable {
        case latest(String)
        case noVersion
        case unreachable
    }

    /// the running version as one query item, and nothing else. the user
    /// agent is set rather than left to URLSession, whose default carries
    /// the build number and the mac's darwin version.
    static func request(version: String) -> URLRequest {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "version", value: version)]
        var request = URLRequest(
            url: components.url!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("andrew-dictate", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func answer(status: Int, body: Data) -> Answer {
        struct Body: Decodable {
            let latest: String
        }

        guard status == 200,
              let decoded = try? JSONDecoder().decode(Body.self, from: body)
        else {
            return .noVersion
        }
        return .latest(decoded.latest)
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// once a day, and never while a dictation or a meeting is running:
    /// the check waits for the next idle moment instead. a last check dated
    /// in the future means the clock moved back, so it does not count.
    static func shouldCheck(
        now: Date,
        lastChecked: Date?,
        enabled: Bool,
        dictating: Bool
    ) -> Bool {
        guard enabled, !dictating else {
            return false
        }
        guard let lastChecked, lastChecked <= now else {
            return true
        }
        return now.timeIntervalSince(lastChecked) >= checkInterval
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
