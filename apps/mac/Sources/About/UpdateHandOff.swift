import AppKit
import os

private let updateLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "update"
)

/// How the update line's click is carried out. `UpdateOffer` says what a
/// click does to the line; this does it, and remembers where the line has
/// got to. a brew install runs `brew upgrade` in the background and the
/// line follows it to `restart to finish`. a dmg install gets the releases
/// page in the browser, which is its own confirmation.
@MainActor
final class UpdateHandOff: ObservableObject {
    /// nil until a click moves the line. after that the click's outcome is
    /// the line, whatever the daily check hears meanwhile.
    @Published private(set) var progress: UpdateOffer.LineState?

    /// defaults to busy, so nothing runs until the app hands over the real
    /// answer.
    var isBusy: () -> Bool = { true }

    private let runningVersion: String
    private let onDiskVersion: () -> String?
    private let relaunch: () -> Void
    private let runner: any CommandRunner
    private let locateBrew: () -> URL?
    private let environment: [String: String]
    private let pasteboard: NSPasteboard
    private let open: (URL) -> Void
    private let logFailure: (String) -> Void
    private let idlePoll: Duration

    init(
        runningVersion: String,
        onDiskVersion: @escaping () -> String?,
        relaunch: @escaping () -> Void,
        runner: any CommandRunner = ProcessRunner(),
        locateBrew: @escaping () -> URL? = { BrewUpgrade.locate() },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pasteboard: NSPasteboard = .general,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        logFailure: @escaping (String) -> Void = {
            updateLogger.error("\($0, privacy: .public)")
        },
        idlePoll: Duration = .seconds(1)
    ) {
        self.runningVersion = runningVersion
        self.onDiskVersion = onDiskVersion
        self.relaunch = relaunch
        self.runner = runner
        self.locateBrew = locateBrew
        self.environment = environment
        self.pasteboard = pasteboard
        self.open = open
        self.logFailure = logFailure
        self.idlePoll = idlePoll
    }

    /// the shipped app's hand-off: this bundle's version, and the bundle
    /// brew installs to, read fresh after the run.
    static func live() -> UpdateHandOff {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return UpdateHandOff(
            runningVersion: version ?? "development",
            onDiskVersion: {
                UpdateCheck.installedVersion(atBundle: BrewUpgrade.installedApp)
            },
            relaunch: { AppRelaunch.now() }
        )
    }

    func state(offering line: UpdateOffer.Line?) -> UpdateOffer.LineState? {
        progress ?? line.map(UpdateOffer.LineState.available)
    }

    /// the line was clicked. the returned task is the upgrade, when the
    /// click started one; the menu has nothing to wait for, the tests do.
    @discardableResult
    func click(offering line: UpdateOffer.Line?) -> Task<Void, Never>? {
        guard let shown = state(offering: line) else {
            return nil
        }
        let click = UpdateOffer.click(
            shown,
            busy: isBusy(),
            brew: locateBrew()
        )
        if click.state != shown {
            progress = click.state
        }

        switch click.effect {
        case nil:
            return nil
        case let .upgrade(brew):
            return Task {
                await upgrade(with: brew)
            }
        case let .open(page):
            open(page)
        case .relaunch:
            relaunch()
        case let .copy(command):
            copy(command)
        }
        return nil
    }

    private func upgrade(with brew: URL) async {
        let result = await runner.run(
            BrewUpgrade.command(brew: brew, environment: environment)
        )
        let onDisk = onDiskVersion()
        let finished = UpdateOffer.finished(
            .updating,
            ending: result.ending,
            onDisk: onDisk,
            running: runningVersion
        )
        if finished == .failedCopied {
            logFailure(why(result, brew: brew, onDisk: onDisk))
            copy(UpdateCheck.upgradeCommand)
        }
        progress = finished
    }

    /// one line for the log: how brew ended, then what brew said last.
    private func why(
        _ result: CommandResult,
        brew: URL,
        onDisk: String?
    ) -> String {
        let reason = BrewUpgrade.reason(inStderr: result.stderr)
            ?? "nothing on stderr"
        switch result.ending {
        case .exited(0):
            let holds = onDisk ?? "no readable version"
            return "brew upgrade exited 0, but /Applications still holds "
                + "\(holds): \(reason)"
        case let .exited(status):
            return "brew upgrade exited \(status): \(reason)"
        case .timedOut:
            return "brew upgrade was stopped after "
                + "\(Int(BrewUpgrade.timeout)) s: \(reason)"
        case .couldNotStart:
            return "brew upgrade could not start "
                + brew.path(percentEncoded: false)
        }
    }

    private func copy(_ command: String) {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }
}
