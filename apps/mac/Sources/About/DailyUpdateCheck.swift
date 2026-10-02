import AppKit
import Combine
import Foundation

/// The update check (ADR 0043): once a day, and when the menu opens on a
/// check more than a day old, it sends the running version to
/// dictate.jass.gg and remembers the newest version it hears. `line` is
/// what the menu shows. It never asks while a dictation or a meeting runs,
/// and with the switch off it never asks at all. Any failure is silence.
@MainActor
final class DailyUpdateCheck: ObservableObject {
    @Published private(set) var line: UpdateOffer.Line?

    typealias Ask = @MainActor (URLRequest) async -> UpdateOffer.Answer

    private let settings: AppSettings
    private let runningVersion: String
    private let onDiskVersion: () -> String?
    private let install: UpdateOffer.Install
    private let now: () -> Date
    private var isBusy: () -> Bool
    private let ask: Ask
    private var isAsking = false
    private var ticker: Task<Void, Never>?
    private var menuObserver: (any NSObjectProtocol)?
    private var switchObserver: AnyCancellable?

    /// `isBusy` defaults to yes, so nothing is asked until `start`
    /// hands over the real answer.
    init(
        settings: AppSettings,
        runningVersion: String,
        onDiskVersion: @escaping () -> String?,
        install: UpdateOffer.Install,
        now: @escaping () -> Date = Date.init,
        isBusy: @escaping () -> Bool = { true },
        ask: @escaping Ask = DailyUpdateCheck.askTheSite
    ) {
        self.settings = settings
        self.runningVersion = runningVersion
        self.onDiskVersion = onDiskVersion
        self.install = install
        self.now = now
        self.isBusy = isBusy
        self.ask = ask

        showLine(enabled: settings.checksForUpdates)
        // @Published fires in willSet, so the new value is the one handed
        // to the sink, not the one on `settings`.
        switchObserver = settings.$checksForUpdates
            .dropFirst()
            .sink { [weak self] enabled in
                self?.showLine(enabled: enabled)
            }
    }

    /// the shipped app's check: this bundle's version, the bundle on disk
    /// re-read each time (brew swaps it under a running app), and the
    /// caskroom deciding brew or dmg.
    static func live(settings: AppSettings = .shared) -> DailyUpdateCheck {
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return DailyUpdateCheck(
            settings: settings,
            runningVersion: version ?? "development",
            onDiskVersion: {
                UpdateCheck.installedVersion(atBundle: bundle.bundleURL)
            },
            install: .detect()
        )
    }

    /// the clock's question. ticks are cheap; the request is once a day.
    func tick() async {
        await askIfDue()
    }

    /// the menu opened. if the last answer is over a day old — the mac
    /// slept through the clock — ask now, so the next look has it.
    func menuOpened() async {
        await askIfDue()
    }

    /// a tick 90 seconds after launch, so the speech model loads first,
    /// then every half hour; and the menu opening, which is any menu in
    /// this app starting to track — the status item's is the only one with
    /// no window behind it, and a day-old check is due whichever opened.
    func start(isBusy: @escaping () -> Bool) {
        guard ticker == nil else {
            return
        }
        self.isBusy = isBusy
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled, let check = self {
                await check.tick()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.menuOpened()
            }
        }
    }

    private func askIfDue() async {
        guard !isAsking,
              UpdateOffer.shouldCheck(
                  now: now(),
                  lastChecked: settings.updateCheckedAt,
                  enabled: settings.checksForUpdates,
                  busy: isBusy()
              )
        else {
            return
        }

        isAsking = true
        let answer = await ask(UpdateOffer.request(version: runningVersion))
        isAsking = false

        switch answer {
        case let .latest(version):
            settings.updateCheckedAt = now()
            settings.newestVersionSeen = version
        case .noVersion:
            settings.updateCheckedAt = now()
        case .unreachable:
            break
        }
        showLine(enabled: settings.checksForUpdates)
    }

    private func showLine(enabled: Bool) {
        line = enabled
            ? UpdateOffer.line(
                latest: settings.newestVersionSeen,
                running: runningVersion,
                onDisk: onDiskVersion(),
                install: install
            )
            : nil
    }

    /// an ephemeral session: no cookies, no cache, nothing kept between
    /// checks. anything short of a reply from the site is `unreachable`.
    nonisolated static func askTheSite(
        _ request: URLRequest
    ) async -> UpdateOffer.Answer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return UpdateOffer.answer(status: status, body: data)
        } catch {
            return .unreachable
        }
    }
}
