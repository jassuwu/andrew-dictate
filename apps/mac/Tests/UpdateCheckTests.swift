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
