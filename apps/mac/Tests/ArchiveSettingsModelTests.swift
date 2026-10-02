import XCTest

/// The dialog in front of `delete all` is the only warning there is — the
/// archive file is unlinked, not trashed — so its sentence is pinned here.
final class ArchiveSettingsModelTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")

    /// Local noon, so the day cannot slide back to the 28th depending on which
    /// time zone the test runs in.
    private let aug29 = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 29, hour: 12)
    )!

    func testTheWarningSaysHowMuchAndHowFarBack() {
        XCTAssertEqual(
            ArchiveSettingsModel.wipeWarning(
                count: 280,
                oldest: aug29,
                locale: british
            ),
            "280 dictations, back to 29 aug. this can’t be undone."
        )
    }

    func testOneDictationIsNotCalledOneDictations() {
        XCTAssertEqual(
            ArchiveSettingsModel.wipeWarning(
                count: 1,
                oldest: aug29,
                locale: british
            ),
            "1 dictation, from 29 aug. this can’t be undone."
        )
    }

    /// An archive with no date to report — nothing kept, or a read that
    /// failed — still has to say the one thing that matters.
    func testWithNoDateTheWarningIsJustTheWarning() {
        XCTAssertEqual(
            ArchiveSettingsModel.wipeWarning(count: 0, oldest: nil),
            "this can’t be undone."
        )
        XCTAssertEqual(
            ArchiveSettingsModel.wipeWarning(count: 4, oldest: nil),
            "this can’t be undone."
        )
    }

    /// the press log has no words in it, but it says when you were at your
    /// mac — so `delete all` takes it too, and leaves neither file behind.
    @MainActor
    func testDeletingEverythingTakesThePressLogWithIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = DictationArchive(
            fileURL: directory.appendingPathComponent("dictations.jsonl")
        )
        let pressLog = PressLogStore(
            fileURL: directory.appendingPathComponent("presses.jsonl")
        )
        try archive.append(
            Dictation(startedAt: aug29, heard: "ship it", inserted: "Ship it.", engine: "v2")
        )
        try pressLog.append(
            PressRecord(
                outcome: .delivered,
                startedAt: aug29,
                mic: nil,
                samples: 16_000,
                peak: 0.2,
                words: 2,
                stages: PressRecord.Stages(ended: 900),
                engine: "v2",
                capped: false,
                retry: false,
                mainStallMs: nil
            )
        )
        let model = ArchiveSettingsModel(archive: archive, pressLog: pressLog)

        model.deleteEverything()

        XCTAssertEqual(model.count, 0)
        XCTAssertNil(model.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pressLog.fileURL.path))
    }

    /// history switched off keeps no dictations, but the press log still
    /// fills — so an empty archive must not grey out the one button that
    /// can wipe it.
    @MainActor
    func testAPressLogAloneStillLeavesSomethingToDelete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = DictationArchive(
            fileURL: directory.appendingPathComponent("dictations.jsonl")
        )
        let pressLog = PressLogStore(
            fileURL: directory.appendingPathComponent("presses.jsonl")
        )
        try pressLog.append(
            PressRecord(
                outcome: .delivered,
                startedAt: aug29,
                mic: nil,
                samples: 16_000,
                peak: 0.2,
                words: 2,
                stages: PressRecord.Stages(ended: 900),
                engine: "v2",
                capped: false,
                retry: false,
                mainStallMs: nil
            )
        )
        let model = ArchiveSettingsModel(archive: archive, pressLog: pressLog)

        XCTAssertEqual(model.count, 0)
        XCTAssertTrue(model.hasAnythingToDelete)

        model.deleteEverything()

        XCTAssertFalse(model.hasAnythingToDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pressLog.fileURL.path))
    }

    /// Every string this app shows is lowercase; a date formatter does not
    /// know that, whichever order the locale puts the day and the month in.
    func testTheDateIsLowercaseInAnyLocale() {
        XCTAssertEqual(
            ArchiveSettingsModel.wipeWarning(
                count: 2,
                oldest: aug29,
                locale: Locale(identifier: "en_US")
            ),
            "2 dictations, back to aug 29. this can’t be undone."
        )
    }
}
