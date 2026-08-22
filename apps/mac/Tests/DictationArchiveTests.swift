import XCTest

final class DictationArchiveTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("dictations.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        )
        super.tearDown()
    }

    private func dictation(
        heard: String = "hello wold",
        inserted: String = "Hello world.",
        at seconds: TimeInterval = 0
    ) -> Dictation {
        Dictation(
            startedAt: Date(timeIntervalSince1970: seconds),
            heard: heard,
            inserted: inserted,
            engine: "v2",
            keyUpToInsertedMilliseconds: 312.4
        )
    }

    func testAnArchiveThatHasNeverBeenWrittenIsEmptyRatherThanAnError() throws {
        let archive = DictationArchive(fileURL: fileURL)

        XCTAssertEqual(try archive.all(), [])
    }

    func testAppendedDictationsReadBackInTheOrderTheyHappened() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation(heard: "first", at: 1))
        try archive.append(dictation(heard: "second", at: 2))
        try archive.append(dictation(heard: "third", at: 3))

        XCTAssertEqual(try archive.all().map(\.heard), ["first", "second", "third"])
    }

    /// Both sides are kept on purpose. The raw text is what a dictionary entry
    /// needs (ticket 004), and holding only the cleaned text would throw away
    /// the one thing that can fix the app's most frequent failure.
    func testBothTheHeardAndTheInsertedTextSurvive() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation(heard: "jason parse", inserted: "JSON parse."))

        let stored = try XCTUnwrap(try archive.all().first)
        XCTAssertEqual(stored.heard, "jason parse")
        XCTAssertEqual(stored.inserted, "JSON parse.")
    }

    func testAppendingDoesNotRewriteWhatIsAlreadyThere() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation(heard: "first", at: 1))
        let afterOne = try Data(contentsOf: fileURL)

        try archive.append(dictation(heard: "second", at: 2))
        let afterTwo = try Data(contentsOf: fileURL)

        XCTAssertTrue(
            afterTwo.starts(with: afterOne),
            "append must not rewrite the file — it grows forever"
        )
    }

    // MARK: - deletion, which is the whole of "until deleted"

    func testDeletingOneLeavesTheRest() throws {
        let archive = DictationArchive(fileURL: fileURL)
        let doomed = dictation(heard: "second", at: 2)
        try archive.append(dictation(heard: "first", at: 1))
        try archive.append(doomed)
        try archive.append(dictation(heard: "third", at: 3))

        try archive.delete(id: doomed.id)

        XCTAssertEqual(try archive.all().map(\.heard), ["first", "third"])
    }

    func testDeletingEverythingLeavesNoFileBehind() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation())
        try archive.deleteAll()

        XCTAssertEqual(try archive.all(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "an emptied archive must not leave a file to be recovered"
        )
    }

    // MARK: - it holds everything you have ever said

    /// The archive is a permanent record of the user's speech. On a shared
    /// Mac the default 0644 would let every other account read it.
    func testTheFileIsNotReadableByOtherUsers() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation())

        let permissions = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    /// One unreadable line must not cost the user every dictation they have.
    func testACorruptLineIsSkippedRatherThanLosingTheArchive() throws {
        let archive = DictationArchive(fileURL: fileURL)
        try archive.append(dictation(heard: "first", at: 1))
        try archive.append(dictation(heard: "second", at: 2))

        var raw = try String(contentsOf: fileURL, encoding: .utf8)
        raw = raw.replacingOccurrences(of: "{", with: "¿", options: [], range: raw.range(of: "{"))
        try raw.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try archive.all().map(\.heard), ["second"])
    }
}
