import XCTest

/// Removing the app's data lists the meeting audio it keeps wherever it
/// lists the spool, and takes it with it.
final class RemovalKeptAudioTests: XCTestCase {
    private var support: URL!
    private var domain: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("removal-kept-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        domain = "gg.jass.dictate.test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: support)
    }

    private func remover() -> Remover {
        Remover(
            supportDirectory: support,
            modelDirectory: support.appendingPathComponent("models"),
            preferencesDomain: domain,
            userDefaults: defaults,
            resetPermissions: { _ in }
        )
    }

    /// kept audio alone, with no spool and no hook log beside it, is still
    /// meeting audio on this mac, with its real size.
    func testKeptAudioAloneIsListedWithTheSpoolAndRemovedWithIt() throws {
        let kept = support.appendingPathComponent("meeting-audio")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(to: kept.appendingPathComponent("abc.m4a"))
        try Data("{}".utf8).write(to: kept.appendingPathComponent("abc.json"))

        let entry = try XCTUnwrap(remover().plan().entries.first { $0.item == .meetingLeftovers })
        XCTAssertTrue(entry.exists)
        XCTAssertGreaterThan(entry.bytes, 4_000)
        XCTAssertEqual(entry.item.title, "meeting audio and the hook log")

        XCTAssertEqual(remover().remove([.meetingLeftovers]), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    }

    /// the plan looks for the folder the app keeps it in.
    func testThePlanLooksWhereTheAudioIsKept() {
        XCTAssertEqual(KeptAudio.folderName, "meeting-audio")
        XCTAssertEqual(KeptAudio.defaultRoot.lastPathComponent, "meeting-audio")
        XCTAssertEqual(
            KeptAudio.defaultRoot.deletingLastPathComponent(),
            MeetingSpool.defaultRoot.deletingLastPathComponent())
    }
}
