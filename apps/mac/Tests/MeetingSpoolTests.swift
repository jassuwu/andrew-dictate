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

    /// Neither audio nor a manifest that reads: there is nothing in it to
    /// lose, and it is swept.
    func testAFolderWithNeitherAudioNorAReadableManifestIsJunkAndIsSwept() throws {
        let junk = root.appendingPathComponent("leftover")
        try FileManager.default.createDirectory(
            at: junk, withIntermediateDirectories: true)
        try "not a manifest".write(
            to: junk.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        let empty = root.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true)

        XCTAssertEqual(spool.orphans().count, 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(spool.unreadableCount(), 0)
    }

    /// A meeting's audio is never deleted for want of a manifest that
    /// reads: the manifest says what app and when, and the audio is the
    /// meeting.
    func testAManifestThatDoesNotDecodeIsSetAsideWithItsAudio() throws {
        let handle = try spool.begin(manifest())
        try Data([0, 1, 2]).write(to: handle.audioURL)
        try "not a manifest".write(to: handle.manifestURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(spool.orphans().count, 0)

        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.folder.path))
        XCTAssertEqual(
            try Data(contentsOf: setAsideFolder(of: handle).appendingPathComponent("audio.caf")),
            Data([0, 1, 2]))
    }

    func testAFolderWithAudioAndNoManifestIsSetAsideWithItsAudio() throws {
        let handle = try spool.begin(manifest())
        try Data([0, 1, 2]).write(to: handle.audioURL)
        try FileManager.default.removeItem(at: handle.manifestURL)

        XCTAssertEqual(spool.orphans().count, 0)

        XCTAssertEqual(spool.unreadableCount(), 1)
        XCTAssertEqual(
            try Data(contentsOf: setAsideFolder(of: handle).appendingPathComponent("audio.caf")),
            Data([0, 1, 2]))
    }

    // MARK: - the look launch takes first

    /// No folder at all is the mac that has never recorded a meeting.
    func testASpoolThatWasNeverMadeHoldsNothing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(spool.mayHoldOrphans())
    }

    func testAnythingLeftInTheSpoolIsWorthALook() throws {
        let handle = try spool.begin(manifest())
        XCTAssertTrue(spool.mayHoldOrphans())

        try spool.finish(handle)
        XCTAssertFalse(spool.mayHoldOrphans())
    }

    /// Set aside means never retried, so it is no reason to build anything.
    func testOnlySetAsideSpoolsAreNothingToDo() throws {
        let handle = try spool.begin(manifest())
        try Data([0]).write(to: handle.audioURL)

        spool.setAside(handle)

        XCTAssertFalse(spool.mayHoldOrphans())
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
    /// Reading it must not fail — a spool whose manifest does not decode is
    /// set aside, and one that only lacked a key would send a meeting that
    /// could have been written out there.
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

    /// A folder with the name of one already set aside — two meetings do not
    /// share one, but a recording that came back and was set aside again
    /// might meet its old self — takes nothing with it that was there.
    func testSettingASpoolAsideNeverReplacesOneAlreadyThere() throws {
        let first = try spool.begin(manifest())
        try Data([1]).write(to: first.audioURL)
        spool.setAside(first)

        try FileManager.default.createDirectory(
            at: first.folder, withIntermediateDirectories: true)
        try Data([2]).write(to: first.audioURL)
        spool.setAside(first)

        XCTAssertEqual(spool.unreadableCount(), 2)
        let audio = try FileManager.default.contentsOfDirectory(atPath: spool.unreadableFolder.path)
            .map { try Data(contentsOf: spool.unreadableFolder
                .appendingPathComponent($0).appendingPathComponent("audio.caf")) }
        XCTAssertEqual(Set(audio), [Data([1]), Data([2])])
    }

    // MARK: - trying again

    /// The recording comes home with its count of tries cleared: it was set
    /// aside on two, and a third from there would set it aside on the first.
    func testASetAsideSpoolComesBackWithItsAttemptsCleared() throws {
        let handle = try spool.begin(manifest())
        try Data([7]).write(to: handle.audioURL)
        let tried = spool.noteAttempt(handle, manifest: manifest())
        spool.noteAttempt(handle, manifest: tried)
        spool.setAside(handle)
        XCTAssertEqual(spool.unreadableCount(), 1)

        let back = spool.bringBackSetAside()

        XCTAssertEqual(back.map(\.handle), [handle])
        XCTAssertEqual(back.map(\.manifest), [manifest()])
        XCTAssertEqual(spool.orphans().map(\.handle), [handle])
        XCTAssertNil(spool.orphans().first?.manifest.attempts)
        XCTAssertEqual(spool.unreadableCount(), 0)
        XCTAssertEqual(try Data(contentsOf: handle.audioURL), Data([7]))
        XCTAssertEqual(permissions(of: handle.manifestURL), 0o600)
    }

    /// What app and when are what the manifest said; with none, the audio
    /// says when it was made, and the meeting is the unnamed one, to be
    /// read with the model the app would pick now.
    func testASetAsideFolderWithNoManifestGetsAMinimalOneSoItCanBeTried() throws {
        let handle = try spool.begin(manifest())
        try Data([7]).write(to: handle.audioURL)
        let madeAt = Date(timeIntervalSince1970: 1_787_100_000)
        try FileManager.default.setAttributes(
            [.creationDate: madeAt], ofItemAtPath: handle.audioURL.path)
        try FileManager.default.removeItem(at: handle.manifestURL)
        _ = spool.orphans()
        XCTAssertEqual(spool.unreadableCount(), 1)

        let back = spool.bringBackSetAside()

        XCTAssertEqual(back.map(\.handle), [handle])
        XCTAssertEqual(back.map(\.manifest), [
            .init(
                app: "meeting", started: madeAt, engine: "whisperLargeV3",
                model: .whisperLargeV3),
        ])
        XCTAssertEqual(spool.orphans().map(\.manifest), back.map(\.manifest))
        XCTAssertEqual(permissions(of: handle.manifestURL), 0o600)
    }

    /// A manifest from a newer build, or one a disk damaged, is not ours to
    /// overwrite: what it says may be the only record of the app and the
    /// hour, so it stays beside the one that replaces it.
    func testAManifestThatDidNotDecodeIsKeptBesideTheMinimalOneThatReplacesIt() throws {
        let handle = try spool.begin(manifest())
        try Data([7]).write(to: handle.audioURL)
        try "from the future".write(to: handle.manifestURL, atomically: true, encoding: .utf8)
        _ = spool.orphans()

        let back = spool.bringBackSetAside()

        XCTAssertEqual(back.map(\.manifest.app), ["meeting"])
        XCTAssertEqual(
            try String(
                contentsOf: handle.folder.appendingPathComponent("manifest.unreadable.json"),
                encoding: .utf8),
            "from the future")
        XCTAssertEqual(spool.orphans().map(\.handle), [handle])
    }

    // MARK: -

    /// Where a set-aside spool's folder ends up.
    private func setAsideFolder(of handle: MeetingSpool.Handle) -> URL {
        spool.unreadableFolder.appendingPathComponent(handle.folder.lastPathComponent)
    }

    private func manifest(started: Date = Date(timeIntervalSince1970: 1_787_000_000)) -> MeetingSpool.Manifest {
        .init(app: "zoom", started: started, engine: "whisper-large-v3-turbo", model: .whisperLargeV3Turbo)
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}
