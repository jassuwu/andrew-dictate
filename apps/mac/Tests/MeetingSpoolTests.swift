import XCTest

final class MeetingSpoolTests: XCTestCase {
    private var root: URL!
    private var spool: MeetingSpool!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-spool-\(UUID().uuidString)")
        spool = MeetingSpool(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testBeginMakesAPrivateFolderWithAManifest() throws {
        let handle = try spool.begin(manifest())

        XCTAssertEqual(permissions(of: root), 0o700)
        XCTAssertEqual(permissions(of: handle.folder), 0o700)
        XCTAssertEqual(permissions(of: handle.manifestURL), 0o600)
        XCTAssertEqual(handle.audioURL.lastPathComponent, "audio.caf")
        XCTAssertFalse(handle.folder.path.contains(" "))
    }

    func testAFolderIsAnOrphanOnlyOnceItHasAudio() throws {
        let handle = try spool.begin(manifest())
        XCTAssertEqual(spool.orphans().count, 0)

        try Data([0, 1, 2]).write(to: handle.audioURL)
        let orphans = spool.orphans()
        XCTAssertEqual(orphans.map(\.handle), [handle])
        XCTAssertEqual(orphans.first?.manifest, manifest())
    }

    func testOrphansAreOldestFirst() throws {
        let late = try spool.begin(manifest(started: Date(timeIntervalSince1970: 2_000)))
        let early = try spool.begin(manifest(started: Date(timeIntervalSince1970: 1_000)))
        try Data([0]).write(to: late.audioURL)
        try Data([0]).write(to: early.audioURL)
        XCTAssertEqual(spool.orphans().map(\.handle), [early, late])
    }

    func testFinishRemovesTheWholeFolder() throws {
        let handle = try spool.begin(manifest())
        try Data([0]).write(to: handle.audioURL)
        try spool.finish(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.folder.path))
        XCTAssertEqual(spool.orphans().count, 0)
    }

    func testJunkFoldersAreSweptWhenLookingForOrphans() throws {
        let junk = root.appendingPathComponent("leftover")
        try FileManager.default.createDirectory(
            at: junk, withIntermediateDirectories: true)
        try "not a manifest".write(
            to: junk.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
    }

    // MARK: - the ones it could not read

    func testAnAttemptIsWrittenDownAndSurvivesARelaunch() throws {
        let handle = try spool.begin(manifest())
        try Data([0]).write(to: handle.audioURL)

        XCTAssertEqual(spool.noteAttempt(handle, manifest: manifest()).attempts, 1)
        XCTAssertEqual(spool.orphans().first?.manifest.attempts, 1)
        XCTAssertEqual(permissions(of: handle.manifestURL), 0o600)
    }

    /// A manifest written before the ledger existed has no `attempts` key.
    /// Reading it must not fail — a spool that fails to decode is swept, and
    /// sweeping one would be losing an hour of someone else's words.
    func testAManifestWithoutTheLedgerStillReads() throws {
        let handle = try spool.begin(manifest())
        try Data([0]).write(to: handle.audioURL)
        let old = """
        {"app":"zoom","engine":"whisper-large-v3-turbo",\
        "model":"whisperLargeV3Turbo","started":"2026-08-29T08:26:40Z"}
        """
        try old.write(to: handle.manifestURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(spool.orphans().count, 1)
        XCTAssertNil(spool.orphans().first?.manifest.attempts)
    }

    /// Kept, never deleted, and never offered to the transcriber again.
    func testASetAsideSpoolIsNoLongerAnOrphan() throws {
        let handle = try spool.begin(manifest())
        try Data([0]).write(to: handle.audioURL)
        XCTAssertEqual(spool.orphans().count, 1)

        spool.setAside(handle)

        XCTAssertEqual(spool.orphans().count, 0)
        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: spool.unreadableFolder
                .appendingPathComponent(handle.folder.lastPathComponent)
                .appendingPathComponent("audio.caf").path))
    }

    // MARK: -

    private func manifest(started: Date = Date(timeIntervalSince1970: 1_787_000_000)) -> MeetingSpool.Manifest {
        .init(app: "zoom", started: started, engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo)
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}
