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
