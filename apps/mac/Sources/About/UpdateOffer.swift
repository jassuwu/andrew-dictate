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

    /// what the click is for, not how it is done: `UpdateHandOff` does
    /// that, running the brew upgrade itself and copying the command only
    /// when it fails.
    enum Action: Equatable, Sendable {
        case brewUpgrade
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
            .brewUpgrade
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

    /// the running version as one query item, and nothing else. two headers
    /// are pinned rather than left to URLSession, whose defaults differ per
    /// mac: the user agent carries the build and the darwin version, and
    /// accept-language carries the region (`en-IN`).
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
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
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

    /// the line from the click on. a brew line runs the upgrade itself, so
    /// the line has to say how that went: the menu is where the click was,
    /// so the menu is where the answer is.
    enum LineState: Equatable, Sendable {
        /// `update to <x>`: the daily check's line, not clicked yet.
        case available(Line)
        /// brew is running. a second click has nothing to add.
        case updating
        /// the new version is in /Applications; this process is the old one.
        case restartToFinish
        /// brew failed, ran out of time, or upgraded nothing. the command
        /// is on the clipboard, so the terminal can say what brew would not.
        case failedCopied

        var title: String {
            switch self {
            case let .available(line):
                line.title
            case .updating:
                "updating…"
            case .restartToFinish:
                "restart to finish"
            case .failedCopied:
                "couldn't update — command copied"
            }
        }

        var isEnabled: Bool {
            self != .updating
        }
    }

    /// what a click asks of the world. the line decides; `UpdateHandOff`
    /// does it.
    enum Effect: Equatable, Sendable {
        /// `brew upgrade` with the brew at this path.
        case upgrade(brew: URL)
        case open(URL)
        /// quit and come back as whatever brew put in /Applications.
        case relaunch
        case copy(String)
    }

    struct Click: Equatable, Sendable {
        let state: LineState
        let effect: Effect?
    }

    /// a click on the line as it is shown. `busy` — a take, a model load or
    /// a meeting — refuses every click quietly, the way the check waits: a
    /// relaunch would end the take, and the clipboard is the inserter's
    /// while it pastes. `brew` is where brew lives; nil, at neither prefix, makes a brew
    /// install a dmg one, since there is nothing here to run.
    static func click(
        _ state: LineState,
        busy: Bool,
        brew: URL?
    ) -> Click {
        guard !busy else {
            return Click(state: state, effect: nil)
        }
        switch state {
        case let .available(line):
            return click(line, brew: brew)
        case .updating:
            return Click(state: state, effect: nil)
        case .restartToFinish:
            return Click(state: state, effect: .relaunch)
        case .failedCopied:
            return Click(
                state: state,
                effect: .copy(UpdateCheck.upgradeCommand)
            )
        }
    }

    private static func click(_ line: Line, brew: URL?) -> Click {
        let state = LineState.available(line)
        switch line.action {
        case .brewUpgrade:
            guard let brew else {
                return Click(state: state, effect: .open(releasesPage))
            }
            return Click(state: .updating, effect: .upgrade(brew: brew))
        case let .openReleasePage(page):
            return Click(state: state, effect: .open(page))
        }
    }

    /// brew's run, judged. exit 0 is not proof: brew is happy to upgrade
    /// nothing. the bundle in /Applications reading newer than this process
    /// is the proof.
    static func finished(
        _ state: LineState,
        ending: CommandResult.Ending,
        onDisk: String?,
        running: String
    ) -> LineState {
        guard state == .updating else {
            return state
        }
        guard ending == .exited(0),
              let onDisk,
              UpdateCheck.isNewer(tag: onDisk, than: running)
        else {
            return .failedCopied
        }
        return .restartToFinish
    }
}
