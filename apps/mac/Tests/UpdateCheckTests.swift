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

    /// a take or a meeting running: the click is refused the way the check
    /// waits, quietly. the line stays as it was.
    func testABusyAppRefusesTheClick() {
        let click = UpdateOffer.click(
            .available(brewLine),
            busy: true,
            brew: optBrew
        )

        XCTAssertEqual(click, UpdateOffer.Click(state: .available(brewLine), effect: nil))
    }

    func testAClickWhileUpdatingDoesNothing() {
        let click = UpdateOffer.click(.updating, busy: false, brew: optBrew)

        XCTAssertEqual(click, UpdateOffer.Click(state: .updating, effect: nil))
    }

    private let releasesPage = URL(
        string: "https://github.com/jassuwu/andrew-dictate/releases/latest"
    )!

    /// a dmg install opens the page the dmg is on; the line stays put.
    func testClickingADmgLineOpensTheReleasesPage() {
        let line = UpdateOffer.Line(
            version: "0.9.5",
            action: .openReleasePage(releasesPage)
        )

        let click = UpdateOffer.click(.available(line), busy: false, brew: optBrew)

        XCTAssertEqual(
            click,
            UpdateOffer.Click(state: .available(line), effect: .open(releasesPage))
        )
    }

    /// a caskroom with no brew at either prefix cannot be upgraded from
    /// here, so it is treated as the dmg install it might as well be.
    func testABrewLineWithNoBrewOpensTheReleasesPage() {
        let click = UpdateOffer.click(.available(brewLine), busy: false, brew: nil)

        XCTAssertEqual(
            click,
            UpdateOffer.Click(state: .available(brewLine), effect: .open(releasesPage))
        )
    }

    /// brew exited clean and /Applications holds something newer than this
    /// process: the only step left is a restart.
    func testAnUpgradeThatLandedOffersTheRestart() {
        let state = UpdateOffer.finished(
            .updating,
            ending: .exited(0),
            onDisk: "0.9.5",
            running: "0.9.4"
        )

        XCTAssertEqual(state, .restartToFinish)
        XCTAssertEqual(state.title, "restart to finish")
        XCTAssertTrue(state.isEnabled)
    }

    func testAFailedOrTimedOutUpgradeIsTheCopiedLine() {
        for ending: CommandResult.Ending in [.exited(1), .timedOut, .couldNotStart] {
            let state = UpdateOffer.finished(
                .updating,
                ending: ending,
                onDisk: "0.9.5",
                running: "0.9.4"
            )

            XCTAssertEqual(state, .failedCopied, "\(ending)")
            XCTAssertEqual(state.title, "couldn't update — command copied")
            XCTAssertTrue(state.isEnabled)
        }
    }

    /// exit 0 is not proof: brew is happy to upgrade nothing. only the
    /// bundle in /Applications reading newer than this process is.
    func testACleanExitWithTheOldVersionOnDiskIsAFailure() {
        for onDisk in ["0.9.4", "0.9.3", nil] {
            XCTAssertEqual(
                UpdateOffer.finished(
                    .updating,
                    ending: .exited(0),
                    onDisk: onDisk,
                    running: "0.9.4"
                ),
                .failedCopied,
                onDisk ?? "nil"
            )
        }
    }

    func testClickingRestartToFinishRelaunches() {
        XCTAssertEqual(
            UpdateOffer.click(.restartToFinish, busy: false, brew: optBrew),
            UpdateOffer.Click(state: .restartToFinish, effect: .relaunch)
        )
    }

    /// the clipboard has had a day since: a click puts the command back.
    func testClickingTheCopiedLineCopiesTheCommandAgain() {
        XCTAssertEqual(
            UpdateOffer.click(.failedCopied, busy: false, brew: optBrew),
            UpdateOffer.Click(
                state: .failedCopied,
                effect: .copy("brew upgrade --cask jassuwu/tap/andrew-dictate")
            )
        )
    }

    /// a relaunch would end the take, and the clipboard is the inserter's
    /// while it pastes.
    func testABusyAppRefusesTheRestartAndTheCopy() {
        for state: UpdateOffer.LineState in [.restartToFinish, .failedCopied] {
            XCTAssertEqual(
                UpdateOffer.click(state, busy: true, brew: optBrew),
                UpdateOffer.Click(state: state, effect: nil)
            )
        }
    }

    // MARK: - the brew run: what is run, where, with what

    /// the copied command and the run command are the same words, so the
    /// fallback never teaches something other than what was tried.
    func testTheRunIsTheCopiedCommandAtAnAbsolutePath() {
        let command = BrewUpgrade.command(
            brew: URL(fileURLWithPath: "/usr/local/bin/brew"),
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(command.executable.path, "/usr/local/bin/brew")
        XCTAssertEqual(
            command.arguments,
            ["upgrade", "--cask", "jassuwu/tap/andrew-dictate"]
        )
        XCTAssertEqual(
            "brew " + command.arguments.joined(separator: " "),
            UpdateCheck.upgradeCommand
        )
        XCTAssertEqual(command.timeout, 600)
    }

    /// an app launched by launchd has a PATH with no brew in it, and brew
    /// run with no terminal must never stop to ask.
    func testTheRunHasBrewsPrefixOnThePathAndNeverAsks() {
        let command = BrewUpgrade.command(
            brew: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(
            command.environment,
            [
                "HOME": "/Users/someone",
                "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOMEBREW_NO_ENV_HINTS": "1",
                "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                "NONINTERACTIVE": "1",
            ]
        )
    }

    /// /opt/homebrew first, /usr/local after it, and a file that is there
    /// but cannot be run is not brew.
    func testBrewIsFoundAtTheFirstPrefixThatHasIt() throws {
        let opt = root.appendingPathComponent("opt/bin/brew")
        let local = root.appendingPathComponent("local/bin/brew")
        let candidates = [opt, local]
        XCTAssertNil(BrewUpgrade.locate(candidates: candidates))

        try makeFile(at: local, executable: true)
        XCTAssertEqual(BrewUpgrade.locate(candidates: candidates), local)

        try makeFile(at: opt, executable: false)
        XCTAssertEqual(BrewUpgrade.locate(candidates: candidates), local)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: opt.path
        )
        XCTAssertEqual(BrewUpgrade.locate(candidates: candidates), opt)
    }

    func testTheShippedPrefixesAreAppleSiliconsThenIntels() {
        XCTAssertEqual(
            BrewUpgrade.candidates.map(\.path),
            ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        )
    }

    /// brew says why last, then trails blank lines behind it.
    func testTheReasonIsBrewsLastNonEmptyStderrLine() {
        XCTAssertEqual(
            BrewUpgrade.reason(
                inStderr: "==> Upgrading 1 outdated package:\n"
                    + "Error: Download failed on Cask 'andrew-dictate'\n\n   \n"
            ),
            "Error: Download failed on Cask 'andrew-dictate'"
        )
        XCTAssertNil(BrewUpgrade.reason(inStderr: ""))
        XCTAssertNil(BrewUpgrade.reason(inStderr: "\n \n"))
    }

    // MARK: - the real runner, run on /bin/sh (never brew)

    private func shell(
        _ script: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 10
    ) async -> CommandResult {
        await ProcessRunner().run(
            Command(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                environment: environment,
                timeout: timeout
            )
        )
    }

    func testTheRunnerKeepsBothStreamsAndTheExitStatus() async {
        let result = await shell("echo out; echo err >&2; exit 3")

        XCTAssertEqual(
            result,
            CommandResult(ending: .exited(3), stdout: "out\n", stderr: "err\n")
        )
    }

    /// more than a pipe holds, so a runner that read only at the end
    /// would hang here instead of finishing.
    func testTheRunnerFinishesAfterALotOfOutput() async {
        let result = await shell(
            "i=0; while [ $i -lt 3000 ]; do "
                + "echo 'a line of brew output, give or take'; "
                + "echo 'and its stderr twin' >&2; i=$((i+1)); done"
        )

        XCTAssertEqual(result.ending, .exited(0))
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 3000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 3000)
    }

    /// no terminal to ask on, and only the environment it was handed.
    func testTheRunnerHasNoTerminalAndOnlyItsOwnEnvironment() async {
        let result = await shell(
            #"test -t 0 || echo no-tty; echo "${ONLY-unset} ${HOME-unset}""#,
            environment: ["ONLY": "this"]
        )

        XCTAssertEqual(result.stdout, "no-tty\nthis unset\n")
    }

    func testTheRunnerStopsACommandAtItsDeadline() async {
        let started = Date()

        let result = await shell("exec sleep 30", timeout: 0.3)

        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTheRunnerSaysSoWhenThereIsNothingToRun() async {
        let result = await ProcessRunner().run(
            Command(
                executable: root.appendingPathComponent("no-brew-here"),
                arguments: [],
                environment: [:],
                timeout: 10
            )
        )

        XCTAssertEqual(result.ending, .couldNotStart)
    }

    /// a run's end only moves a line that is waiting on it.
    func testOnlyAnUpdatingLineIsFinished() {
        for state: UpdateOffer.LineState in [.available(brewLine), .restartToFinish, .failedCopied] {
            XCTAssertEqual(
                UpdateOffer.finished(
                    state,
                    ending: .exited(1),
                    onDisk: nil,
                    running: "0.9.4"
                ),
                state
            )
        }
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

    private func makeFile(at url: URL, executable: Bool) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
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
