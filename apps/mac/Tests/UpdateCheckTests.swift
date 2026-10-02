import AppKit
import XCTest

final class UpdateCheckTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-check-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testANewerTagIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.8.0", than: "0.7.1"))
        XCTAssertTrue(UpdateCheck.isNewer(tag: "1.0.0", than: "0.9.9"))
    }

    func testTheSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7.1", than: "0.7.1"))
    }

    func testAnOlderTagIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7.0", than: "0.7.1"))
    }

    /// numeric, not lexicographic: "10" beats "9".
    func testDoubleDigitComponentsCompareNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.7.10", than: "0.7.9"))
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.10.0", than: "0.9.9"))
    }

    /// a missing component is a zero, not a mismatch.
    func testShorterTagsPadWithZeros() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.8", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.7", than: "0.7.0"))
    }

    /// the about window prints this for the user to paste, so a typo in the
    /// tap name would land in a stranger's terminal rather than in a build.
    func testTheUpgradeCommandIsExact() {
        XCTAssertEqual(
            UpdateCheck.upgradeCommand,
            "brew upgrade --cask jassuwu/tap/andrew-dictate"
        )
    }

    /// the bundle on disk is the one brew just replaced; the running
    /// process is the one still answering the click.
    func testTheInstalledVersionIsReadOffDisk() throws {
        let bundle = try makeBundle(version: "0.9.3")

        XCTAssertEqual(UpdateCheck.installedVersion(atBundle: bundle), "0.9.3")
        XCTAssertTrue(
            UpdateCheck.isNewer(
                tag: UpdateCheck.installedVersion(atBundle: bundle) ?? "",
                than: "0.9.2"
            )
        )
        XCTAssertFalse(
            UpdateCheck.isNewer(
                tag: UpdateCheck.installedVersion(atBundle: bundle) ?? "",
                than: "0.9.3"
            )
        )
    }

    /// a dev build, a moved bundle or a half-written plist must never say
    /// "already installed" — nil is the only honest answer.
    func testAnUnreadableBundleHasNoVersion() throws {
        XCTAssertNil(
            UpdateCheck.installedVersion(
                atBundle: root.appendingPathComponent("Nothing.app")
            )
        )
        XCTAssertNil(
            UpdateCheck.installedVersion(atBundle: try makeBundle(version: nil))
        )
        XCTAssertNil(
            UpdateCheck.installedVersion(
                atBundle: try makeBundle(version: "0.9.3", garbled: true)
            )
        )
    }

    /// a garbage response must never produce an upgrade prompt.
    func testUnparseableTagsAreNeverNewer() {
        XCTAssertFalse(UpdateCheck.isNewer(tag: "latest", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.8.beta", than: "0.7.1"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "", than: "0.7.1"))
        XCTAssertFalse(
            UpdateCheck.isNewer(tag: "v0.8.0", than: "development")
        )
    }

    // MARK: - the update line: which version earns it

    func testANewerVersionEarnsTheLine() {
        let line = UpdateOffer.line(
            latest: "0.9.5",
            running: "0.9.4",
            install: .dmg
        )

        XCTAssertEqual(line?.title, "update to 0.9.5")
    }

    /// numeric, not lexicographic, all the way to the menu.
    func testZeroNineTenBeatsZeroNineNine() {
        let line = UpdateOffer.line(
            latest: "0.9.10",
            running: "0.9.9",
            install: .dmg
        )

        XCTAssertEqual(line?.title, "update to 0.9.10")
    }

    func testTheSameOrAnOlderVersionHasNoLine() {
        for latest in ["0.9.4", "v0.9.4", "0.9.3", "0.8.12"] {
            XCTAssertNil(
                UpdateOffer.line(
                    latest: latest,
                    running: "0.9.4",
                    install: .homebrew
                ),
                latest
            )
        }
    }

    /// no answer, or an answer that is not a version, is silence.
    func testNoAnswerHasNoLine() {
        for latest in [nil, "", "latest", "v0.9.beta"] {
            XCTAssertNil(
                UpdateOffer.line(
                    latest: latest,
                    running: "0.9.4",
                    install: .homebrew
                ),
                latest ?? "nil"
            )
        }
    }

    /// brew already put the new bundle on disk; this process is the old
    /// one. offering the same upgrade again would be a lie.
    func testAnUpgradeAlreadyOnDiskHasNoLine() {
        XCTAssertNil(
            UpdateOffer.line(
                latest: "0.9.5",
                running: "0.9.4",
                onDisk: "0.9.5",
                install: .homebrew
            )
        )
        XCTAssertEqual(
            UpdateOffer.line(
                latest: "0.9.6",
                running: "0.9.4",
                onDisk: "0.9.5",
                install: .homebrew
            )?.title,
            "update to 0.9.6"
        )
    }

    // MARK: - the update line: what clicking it does

    /// brew put it there, so brew replaces it — with the exact tap line.
    func testABrewInstallIsOfferedTheUpgradeCommand() {
        let line = UpdateOffer.line(
            latest: "0.9.5",
            running: "0.9.4",
            install: .homebrew
        )

        XCTAssertEqual(
            line?.action,
            .brewUpgrade("brew upgrade --cask jassuwu/tap/andrew-dictate")
        )
    }

    /// a dmg user handed a brew line would paste an error into terminal.
    func testADmgInstallIsSentToTheReleasesPage() {
        let line = UpdateOffer.line(
            latest: "0.9.5",
            running: "0.9.4",
            install: .dmg
        )

        XCTAssertEqual(
            line?.action,
            .openReleasePage(
                URL(
                    string: "https://github.com/jassuwu/andrew-dictate/releases/latest"
                )!
            )
        )
    }

    func testTheInstallIsHomebrewOnlyWhenTheCaskroomHasIt() throws {
        let caskroom = root.appendingPathComponent("andrew-dictate")
        XCTAssertEqual(UpdateOffer.Install.detect(caskroom: caskroom), .dmg)

        try FileManager.default.createDirectory(
            at: caskroom,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            UpdateOffer.Install.detect(caskroom: caskroom),
            .homebrew
        )
    }

    // MARK: - the update check: when it may ask

    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    private func hours(_ count: Double) -> TimeInterval {
        count * 60 * 60
    }

    func testANeverCheckedInstallIsDue() {
        XCTAssertTrue(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: nil,
                enabled: true,
                dictating: false
            )
        )
    }

    /// once a day: not at 23 hours, yes at 24.
    func testItIsDueOnceADay() {
        XCTAssertFalse(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: noon.addingTimeInterval(-hours(23)),
                enabled: true,
                dictating: false
            )
        )
        XCTAssertTrue(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: noon.addingTimeInterval(-hours(24)),
                enabled: true,
                dictating: false
            )
        )
    }

    /// a clock set back would otherwise silence it until the date catches up.
    func testALastCheckInTheFutureIsDue() {
        XCTAssertTrue(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: noon.addingTimeInterval(hours(48)),
                enabled: true,
                dictating: false
            )
        )
    }

    func testItNeverAsksWhileDictating() {
        XCTAssertFalse(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: nil,
                enabled: true,
                dictating: true
            )
        )
    }

    func testTheSwitchOffMeansItNeverAsks() {
        XCTAssertFalse(
            UpdateOffer.shouldCheck(
                now: noon,
                lastChecked: nil,
                enabled: false,
                dictating: false
            )
        )
    }

    // MARK: - the update check: what it sends and what it hears

    /// the version, and nothing else: no id, no cookie. the two headers
    /// URLSession would fill per mac are pinned — its user agent carries
    /// the build and the darwin version, its accept-language the region
    /// (`en-IN`) — so every copy sends the same bytes but the version.
    func testTheRequestCarriesTheVersionAndNothingElse() {
        let request = UpdateOffer.request(version: "0.9.4")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://dictate.jass.gg/api/latest?version=0.9.4"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.allHTTPHeaderFields,
            ["User-Agent": "andrew-dictate", "Accept-Language": "en"]
        )
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.httpBody)
    }

    func testTheAnswerIsTheLatestVersion() {
        XCTAssertEqual(
            UpdateOffer.answer(
                status: 200,
                body: Data(#"{"latest":"0.9.5"}"#.utf8)
            ),
            .latest("0.9.5")
        )
    }

    /// the site answered, just not with a version: that still counts as
    /// today's check, so a broken endpoint is asked once a day, not hourly.
    func testAnythingElseFromTheSiteIsAnAnswerWithoutAVersion() {
        let answers = [
            UpdateOffer.answer(status: 502, body: Data(#"{"error":"x"}"#.utf8)),
            UpdateOffer.answer(status: 200, body: Data("<html>".utf8)),
            UpdateOffer.answer(status: 200, body: Data(#"{"latest":5}"#.utf8)),
        ]

        XCTAssertEqual(answers, [.noVersion, .noVersion, .noVersion])
    }

    // MARK: - the daily check: the clock, the menu, the switch

    @MainActor
    func testTheFirstCheckSendsTheVersionAndOffersTheLine() async {
        let world = CheckWorld(now: noon)
        world.answer = .latest("0.9.5")

        await world.check.tick()

        XCTAssertEqual(
            world.asked.map { $0.url?.absoluteString },
            ["https://dictate.jass.gg/api/latest?version=0.9.4"]
        )
        XCTAssertEqual(world.check.line?.title, "update to 0.9.5")
        XCTAssertEqual(world.settings.updateCheckedAt, noon)
    }

    @MainActor
    func testTheClockAsksOnceADay() async {
        let world = CheckWorld(now: noon)

        await world.check.tick()
        world.now = noon.addingTimeInterval(hours(1))
        await world.check.tick()
        world.now = noon.addingTimeInterval(hours(23))
        await world.check.tick()
        XCTAssertEqual(world.asked.count, 1)

        world.now = noon.addingTimeInterval(hours(24))
        await world.check.tick()
        XCTAssertEqual(world.asked.count, 2)
    }

    /// a mac that slept through the timer catches up the moment you look.
    @MainActor
    func testOpeningTheMenuOnAStaleCheckAsks() async {
        let world = CheckWorld(now: noon)
        world.settings.updateCheckedAt = noon.addingTimeInterval(-hours(30))

        await world.check.menuOpened()

        XCTAssertEqual(world.asked.count, 1)
    }

    @MainActor
    func testOpeningTheMenuOnAFreshCheckDoesNotAsk() async {
        let world = CheckWorld(now: noon)
        world.settings.updateCheckedAt = noon.addingTimeInterval(-hours(2))

        await world.check.menuOpened()

        XCTAssertTrue(world.asked.isEmpty)
    }

    @MainActor
    func testSwitchedOffItMakesNoRequestAndShowsNoLine() async {
        let world = CheckWorld(now: noon)
        world.settings.newestVersionSeen = "0.9.5"
        world.settings.checksForUpdates = false

        await world.check.tick()
        await world.check.menuOpened()

        XCTAssertTrue(world.asked.isEmpty)
        XCTAssertNil(world.check.line)
    }

    @MainActor
    func testSwitchingItOffTakesTheLineAway() async {
        let world = CheckWorld(now: noon)
        world.answer = .latest("0.9.5")
        await world.check.tick()
        XCTAssertNotNil(world.check.line)

        world.settings.checksForUpdates = false

        XCTAssertNil(world.check.line)
    }

    /// dictating, it waits; the next tick after the take is the one.
    @MainActor
    func testItWaitsOutADictation() async {
        let world = CheckWorld(now: noon)
        world.dictating = true

        await world.check.tick()
        await world.check.menuOpened()
        XCTAssertTrue(world.asked.isEmpty)

        world.dictating = false
        await world.check.tick()
        XCTAssertEqual(world.asked.count, 1)
    }

    /// offline is not today's check: on wake the timer fires before the
    /// wi-fi is back, and a day of silence would follow.
    @MainActor
    func testAnUnreachableSiteIsAskedAgainOnTheNextTick() async {
        let world = CheckWorld(now: noon)
        world.answer = .unreachable

        await world.check.tick()
        XCTAssertNil(world.settings.updateCheckedAt)
        XCTAssertNil(world.check.line)

        world.answer = .latest("0.9.5")
        world.now = noon.addingTimeInterval(hours(0.5))
        await world.check.tick()
        XCTAssertEqual(world.asked.count, 2)
        XCTAssertEqual(world.check.line?.title, "update to 0.9.5")
    }

    /// a site that answers without a version still used up today's check,
    /// and the version it said before is still the newest we know of.
    @MainActor
    func testAnAnswerWithoutAVersionKeepsTheLastLine() async {
        let world = CheckWorld(now: noon)
        world.settings.newestVersionSeen = "0.9.5"
        world.answer = .noVersion

        await world.check.tick()

        XCTAssertEqual(world.settings.updateCheckedAt, noon)
        XCTAssertEqual(world.check.line?.title, "update to 0.9.5")
    }

    /// yesterday's answer is still on the menu after a relaunch.
    @MainActor
    func testTheLineSurvivesARelaunch() {
        let world = CheckWorld(now: noon)
        world.settings.newestVersionSeen = "0.9.5"

        let relaunched = world.makeCheck()

        XCTAssertEqual(relaunched.line?.title, "update to 0.9.5")
    }

    // MARK: - the update line: one click, from available to restart

    private let brewLine = UpdateOffer.Line(
        version: "0.9.5",
        action: .brewUpgrade("brew upgrade --cask jassuwu/tap/andrew-dictate")
    )

    private let optBrew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    /// the click runs brew where it lives, and the line says so at once.
    func testClickingABrewLineStartsTheUpgrade() {
        let click = UpdateOffer.click(
            .available(brewLine),
            busy: false,
            brew: optBrew
        )

        XCTAssertEqual(click.state, .updating)
        XCTAssertEqual(click.effect, .upgrade(brew: optBrew))
        XCTAssertEqual(click.state.title, "updating…")
        XCTAssertFalse(click.state.isEnabled)
    }

    // MARK: - the hand-off: what the click does today

    /// the menu closes on the click, so the pill says what happened.
    @MainActor
    func testABrewLineCopiesTheCommandAndSaysSo() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        var said: [String] = []
        let handOff = ManualHandOff(
            pasteboard: pasteboard,
            open: { opened.append($0) },
            confirm: { said.append($0) }
        )

        handOff.perform(
            .brewUpgrade("brew upgrade --cask jassuwu/tap/andrew-dictate")
        )

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "brew upgrade --cask jassuwu/tap/andrew-dictate"
        )
        XCTAssertEqual(said, ["copied — paste it in terminal"])
        XCTAssertTrue(opened.isEmpty)
    }

    /// the browser opening is the confirmation; the clipboard is left alone.
    @MainActor
    func testADmgLineOpensTheReleasesPage() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        var said: [String] = []
        let handOff = ManualHandOff(
            pasteboard: pasteboard,
            open: { opened.append($0) },
            confirm: { said.append($0) }
        )
        let page = URL(
            string: "https://github.com/jassuwu/andrew-dictate/releases/latest"
        )!

        handOff.perform(.openReleasePage(page))

        XCTAssertEqual(opened, [page])
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(said.isEmpty)
    }

    /// a throwaway `Andrew Dictate.app`, with or without a readable plist.
    private func makeBundle(
        version: String?,
        garbled: Bool = false
    ) throws -> URL {
        let bundle = root
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Andrew Dictate.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let plist = contents.appendingPathComponent("Info.plist")
        if garbled {
            try Data("not a plist".utf8).write(to: plist)
        } else if let version {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version],
                format: .xml,
                options: 0
            )
            try data.write(to: plist)
        }
        return bundle
    }
}

/// a daily check with the clock, the network and dictation in the test's
/// hands: running 0.9.4 from a dmg, nothing newer on disk, and a site that
/// answers 0.9.4 until told otherwise.
@MainActor
private final class CheckWorld {
    let settings: AppSettings
    var now: Date
    var dictating = false
    var answer: UpdateOffer.Answer = .latest("0.9.4")
    private(set) var asked: [URLRequest] = []
    private(set) lazy var check: DailyUpdateCheck = makeCheck()
    private let suiteName = "AndrewDictateTests.UpdateCheck.\(UUID().uuidString)"

    init(now: Date) {
        settings = AppSettings(
            userDefaults: UserDefaults(suiteName: suiteName)!
        )
        self.now = now
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func makeCheck() -> DailyUpdateCheck {
        DailyUpdateCheck(
            settings: settings,
            runningVersion: "0.9.4",
            onDiskVersion: { nil },
            install: .dmg,
            now: { [unowned self] in now },
            isDictating: { [unowned self] in dictating },
            ask: { [unowned self] request in
                asked.append(request)
                return answer
            }
        )
    }
}
